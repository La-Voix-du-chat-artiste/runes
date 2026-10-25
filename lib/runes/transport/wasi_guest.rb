# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "base"

module Runes
  module Transport
    # WasiGuest — the transport whose fabric lives in a WASI guest.
    #
    # The first REAL guest: until now the WASM sandbox (Runes::WASM::VMManager)
    # ran one-shot, stateless tool scripts. This adapter instead runs a
    # long-lived guest — wasm/transport_guest.rb, a self-contained Ruby
    # program — that HOLDS the fabric state: subscriptions, retained
    # messages, shared-group round-robin. The host adapter implements the
    # ordinary Runes::Transport::Base contract; every call becomes a framed
    # op on the guest's mapped work directory, and the guest's deliveries
    # stream back as frames (protocol: the guest file's header). The guest
    # program is the same bytes under CRuby (the suite spawns it directly),
    # under ruby.wasm (this adapter's default spawn), and — the point of the
    # exercise — under any WASI p1 runtime, including the Spinel-compiled
    # fleet runtime later: the bridge protocol is the seam.
    #
    # Why files, not pipes: WASI p1 gives the guest a preopened directory
    # and nothing else bidirectional — guest stdout is consumed by the host
    # only as a log, and a FIFO stdin busy-polls under wasmtime. Numbered
    # JSON files (tmp + rename, both directions) are atomic, ordered, and
    # need no runtime support beyond fd_read on the preopen.
    #
    # Ordering: subscribe/unsubscribe/publish/stop ops carry a "ref" and the
    # guest acks AFTER applying them, so a publish cannot overtake the
    # subscribe it depends on across the bridge.
    class WasiGuest < Base
      DEFAULT_GUEST = File.expand_path("../../../wasm/transport_guest.rb", __dir__)
      DEFAULT_HOST = File.expand_path("../../../wasm/wasm_host.rb", __dir__)
      DEFAULT_POLL_INTERVAL = 0.005
      DEFAULT_BOOT_TIMEOUT = 30
      DEFAULT_ACK_TIMEOUT = 10

      # A running guest process/VM. The default #wasm_spawn returns a
      # process-backed handle; tests inject a CRuby subprocess handle — the
      # adapter only needs alive?/wait/stop.
      class Handle
        def initialize(alive:, wait: nil, stop: nil)
          @alive_fn = alive
          @wait_fn = wait
          @stop_fn = stop
        end

        def alive? = @alive_fn.call

        def wait(timeout = nil)
          @wait_fn ? @wait_fn.call(timeout) : true
        end

        def stop
          @stop_fn&.call
        end
      end

      def initialize(wasm_path: nil, guest_path: nil, work_dir: nil, spawn: nil,
                     poll_interval: DEFAULT_POLL_INTERVAL, boot_timeout: DEFAULT_BOOT_TIMEOUT,
                     ack_timeout: DEFAULT_ACK_TIMEOUT, **options)
        super(**options)
        @wasm_path = wasm_path || File.expand_path("../../../../ruby.wasm", __dir__)
        @guest_path = guest_path || DEFAULT_GUEST
        @given_work_dir = work_dir
        @poll_interval = poll_interval
        @boot_timeout = boot_timeout
        @ack_timeout = ack_timeout
        @spawn = spawn || method(:wasm_spawn)
        @connected = false
        @op_seq = 0
        @sub_seq = 0
        @pending = {} # ref => Queue
        @pending_mutex = Mutex.new
        @last_frame_seq = -1
      end

      attr_reader :work_dir

      def connect
        return self if @connected

        @work_dir = @given_work_dir || Dir.mktmpdir("runes-wasi-guest-")
        FileUtils.mkdir_p(File.join(@work_dir, "inbox"))
        FileUtils.mkdir_p(File.join(@work_dir, "outbox"))
        @hello = Queue.new
        @stop_pump = false
        @handle = @spawn.call(work_dir: @work_dir, program_path: @guest_path,
                              wasm_path: @wasm_path, log_dir: @work_dir)
        @pump = Thread.new { pump_loop }
        unless wait_for(@hello, @boot_timeout)
          begin
            @handle.stop
          rescue StandardError
            nil
          end
          # The dir stays: guest.log / guest-stderr.log are the only
          # diagnostics for why the boot never said hello.
          raise Error, "wasi_guest: guest did not boot within #{@boot_timeout}s " \
                       "(work dir: #{@work_dir}; guest log: #{File.join(@work_dir, 'guest.log')}; " \
                       "child stderr: #{File.join(@work_dir, 'child-stderr.log')})"
        end
        @connected = true
        self
      end

      def disconnect
        return self unless @connected

        @connected = false
        begin
          ref = write_op("op" => "stop")
          wait_ack(ref, 5)
        rescue Error
          nil # the guest is already gone; teardown continues
        end
        @handle.stop
        @stop_pump = true
        @pump&.join(2)
        @pump&.kill if @pump&.alive?
        FileUtils.rm_rf(@work_dir) if @work_dir && !@given_work_dir && Dir.exist?(@work_dir)
        self
      end

      def connected?
        @connected && @handle&.alive?
      end

      def supports_groups?
        true
      end

      def supports_properties?
        true
      end

      def publish(topic, payload, qos: 0, retain: false, properties: {})
        ensure_connected!
        unless Runes::Transport::TopicFilter.valid_topic?(topic)
          raise Error, "topic #{topic.inspect} must not contain wildcards"
        end
        raise Error, "qos #{qos} not in 0..2" unless valid_qos?(qos)

        ref = write_op("op" => "publish", "topic" => topic, "payload" => payload.to_s,
                       "qos" => qos, "retain" => retain == true,
                       "properties" => stringify_keys(properties))
        wait_ack(ref, @ack_timeout)
        self
      end

      def subscribe(filter, qos: 0, group: nil, &block)
        ensure_connected!
        raise ArgumentError, "a subscription needs a block" unless block

        id = "sub-#{@sub_seq += 1}"
        subscription = Subscription.new(id, filter, group, qos, block, self)
        # Register BEFORE the op lands: the ack guarantees the guest knows
        # the sub, so a delivery can race the ack but never an unregistered
        # handler.
        register(subscription)
        begin
          ref = write_op("op" => "subscribe", "id" => id, "filter" => filter, "group" => group, "qos" => qos)
          wait_ack(ref, @ack_timeout)
        rescue Error
          @mutex.synchronize { @subscriptions.delete(subscription) }
          raise
        end
        subscription
      end

      def unsubscribe(subscription)
        return false unless subscription

        removed = @mutex.synchronize do
          @subscriptions.delete(subscription)
        end
        return false unless removed

        if connected?
          ref = write_op("op" => "unsubscribe", "id" => subscription.id)
          wait_ack(ref, @ack_timeout)
        end
        true
      end

      private

      def ensure_connected!
        raise Error, "#{describe} is not connected" unless connected?
      end

      # ---- the bridge ----

      def inbox_dir = File.join(@work_dir, "inbox")
      def outbox_dir = File.join(@work_dir, "outbox")

      def write_op(hash)
        ref = (@op_seq += 1)
        name = format("%06d.json", ref)
        tmp = File.join(inbox_dir, "tmp_#{name}")
        final = File.join(inbox_dir, name)
        File.write(tmp, Runes::Json.generate(hash.merge("ref" => ref)))
        File.rename(tmp, final)
        ref
      end

      def wait_ack(ref, timeout)
        queue = @pending_mutex.synchronize { @pending[ref] ||= Queue.new }
        wait_for(queue, timeout) || raise(Error, "wasi_guest: op #{ref} was not acked within #{timeout}s")
      ensure
        @pending_mutex.synchronize { @pending.delete(ref) }
      end

      def wait_for(queue, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          return true if queue.pop(true)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.002
        rescue ThreadError # empty queue
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.002
        end
      end

      def pump_loop
        until @stop_pump
          scan_outbox
          sleep @poll_interval
        end
      rescue StandardError => e
        warn "[WasiGuest] frame pump died: #{e.class}: #{e.message}"
      end

      def scan_outbox
        Dir[File.join(outbox_dir, "*.json")].sort.each do |path|
          # tmp_* frames are the guest's write-in-progress; the rename is
          # the visibility point (same rule as the host's inbox writes).
          next if File.basename(path).start_with?("tmp_")

          seq = File.basename(path)[/\A[0-9]+/].to_i
          next if seq <= @last_frame_seq

          frame = begin
            Runes::Json.parse(File.read(path))
          rescue Runes::Json::ParseError
            next # partial rename window; retried on the next scan
          end
          dispatch_frame(frame)
          @last_frame_seq = seq
          File.delete(path)
        end
      end

      def dispatch_frame(frame)
        case frame["kind"]
        when "hello"
          @hello << true
        when "ack"
          @pending_mutex.synchronize { @pending[frame["ref"]] }&.push(true)
        when "delivery"
          sub = @mutex.synchronize { @subscriptions.find { |s| s.id == frame["sub"] } }
          unless sub
            warn "[WasiGuest] delivery for unknown sub #{frame['sub'].inspect} dropped"
            return
          end
          deliver(sub, frame["topic"], frame["payload"], symbolize_keys(frame["properties"]),
                  qos: frame["qos"] || 0, retain: frame["retain"] == true)
        else
          warn "[WasiGuest] unknown frame kind #{frame['kind'].inspect}"
        end
      end

      def stringify_keys(hash)
        (hash || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end

      def symbolize_keys(hash)
        (hash || {}).each_with_object({}) do |(k, v), out|
          out[k.to_s.tr("-", "_").to_sym] = v
        end
      end

      # ---- the default spawn: ruby.wasm in a child OS process ----
      #
      # In-process is not an option: wasmtime-ruby's `invoke` holds the
      # CRuby GVL while guest code runs, so a long-lived guest starves this
      # process's pump thread and every timer (measured: host heartbeats
      # never landed while a guest loop was alive, even at a 1 s poll).
      # The child owns the VM; the parent only touches the bridge files.
      def wasm_spawn(work_dir:, program_path:, wasm_path:, log_dir:)
        raise Error, "wasi_guest: wasm binary not found: #{wasm_path}" unless File.file?(wasm_path)
        raise Error, "wasi_guest: guest host script not found: #{DEFAULT_HOST}" unless File.file?(DEFAULT_HOST)

        pid = Process.spawn(
          RbConfig.ruby, DEFAULT_HOST, work_dir, wasm_path, program_path,
          out: File.join(log_dir, "child-stdout.log"),
          err: File.join(log_dir, "child-stderr.log")
        )
        subprocess_handle(pid)
      rescue SystemCallError => e
        raise Error, "wasi_guest: guest boot failed: #{e.class}: #{e.message}"
      end

      # A Process-backed Handle. `reap` is the single owner of the child's
      # exit status (guarded by a mutex) so `alive?`, `wait` and `stop`
      # cannot race each other into Errno::ECHILD.
      def subprocess_handle(pid)
        mutex = Mutex.new
        exited = false
        reap = lambda do
          mutex.synchronize do
            if exited
              true
            else
              begin
                exited = true if Process.wait(pid, Process::WNOHANG)
                exited
              rescue Errno::ECHILD
                exited = true
              end
            end
          end
        end

        Handle.new(
          alive: -> { !reap.call && (Process.kill(0, pid) rescue false) },
          wait: lambda do |timeout|
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
            loop do
              return true if reap.call
              return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

              sleep 0.02
            end
          end,
          stop: lambda do
            unless reap.call
              begin
                Process.kill("TERM", pid)
              rescue Errno::ESRCH
                nil
              end
              60.times do
                break if reap.call

                sleep 0.05
              end
              unless reap.call
                begin
                  Process.kill("KILL", pid)
                rescue Errno::ESRCH
                  nil
                end
              end
            end
            20.times do
              break if reap.call

              sleep 0.05
            end
            begin
              Process.wait(pid)
            rescue Errno::ECHILD
              nil
            end
          end
        )
      end
    end
  end
end
