# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "rbconfig"

require_relative "../lib/runes/transport"
require_relative "../lib/runes/transport/wasi_guest"

# The in-process transport guest (thread: WASI — the first real guest).
# The fabric state lives in wasm/transport_guest.rb, a self-contained Ruby
# program; these tests spawn it with CRuby (same bytes the ruby.wasm spawn
# embeds), so the whole adapter + guest + bridge protocol is exercised
# hermetically. The one test that boots the real ruby.wasm under wasmtime
# is opt-in via RUNES_WASM=real (module compile is tens of seconds).
class WasiGuestTest < Minitest::Test
  GUEST = File.expand_path("../wasm/transport_guest.rb", __dir__)

  def setup
    @transport = nil
  end

  def teardown
    @transport&.disconnect
  end

  def build_transport(**opts)
    @transport = Runes::Transport::WasiGuest.new(spawn: cruby_spawn,
                                                 boot_timeout: 60, ack_timeout: 30, **opts)
  end

  # ---- a subprocess-backed Handle (the suite's stand-in for the VM) ----

  def cruby_spawn
    lambda do |work_dir:, program_path:, **_kw|
      pid = spawn(RbConfig.ruby, program_path, work_dir, out: File::NULL, err: File::NULL)
      subprocess_handle(pid)
    end
  end

  def subprocess_handle(pid)
    Runes::Transport::WasiGuest::Handle.new(
      alive: lambda {
        begin
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end
      },
      wait: lambda do |timeout|
        deadline = Time.now + timeout.to_f
        loop do
          return true if Process.wait(pid, Process::WNOHANG)
          return false if Time.now >= deadline

          sleep 0.02
        end
      rescue Errno::ECHILD
        true
      end,
      stop: lambda do
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          nil
        end
        40.times do
          break if (Process.wait(pid, Process::WNOHANG) rescue true)

          sleep 0.05
        end
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
      end
    )
  end

  def wait_until(deadline_s: 5)
    deadline = Time.now + deadline_s
    until yield
      flunk "condition not met within #{deadline_s}s" if Time.now > deadline

      sleep 0.01
    end
  end

  # ---- the contract, through the bridge ----

  def test_round_trip_through_the_guest
    build_transport.connect
    received = []
    @transport.subscribe("runes/test/#") { |m| received << m }

    @transport.publish("runes/test/one", JSON.generate("n" => 1))

    wait_until { received.size == 1 }
    assert_equal "runes/test/one", received.first.topic
    assert_equal({ "n" => 1 }, JSON.parse(received.first.payload))
    assert_equal 0, received.first.qos
  end

  def test_retained_replay_and_single_level_wildcard
    build_transport.connect
    @transport.publish("runes/retained/a", "early", retain: true)

    replayed = []
    @transport.subscribe("runes/retained/+") { |m| replayed << m }

    wait_until { replayed.size == 1 }
    assert_equal "early", replayed.first.payload
    assert_equal true, replayed.first.retain
  end

  def test_shared_group_splits_each_message_exactly_once
    build_transport.connect
    left, right = [], []
    @transport.subscribe("runes/jobs", group: "workers") { |m| left << m }
    @transport.subscribe("runes/jobs", group: "workers") { |m| right << m }

    4.times { |i| @transport.publish("runes/jobs", "job-#{i}") }

    wait_until { left.size + right.size == 4 }
    payloads = (left + right).map(&:payload)
    assert_equal %w[job-0 job-1 job-2 job-3], payloads.sort
    assert_operator left.size, :>=, 1
    assert_operator right.size, :>=, 1
    sleep 0.1
    assert_equal 4, left.size + right.size, "no message may be delivered twice"
  end

  def test_properties_cross_the_bridge_intact
    build_transport.connect
    received = []
    @transport.subscribe("runes/props") { |m| received << m }

    @transport.publish("runes/props", "x", qos: 1,
                                         properties: { response_topic: "runes/reply/me",
                                                       correlation_id: "corr-9",
                                                       user_properties: { "a2a-status" => "working" } })

    wait_until { received.size == 1 }
    m = received.first
    assert_equal "runes/reply/me", m.response_topic
    assert_equal "corr-9", m.correlation_id
    assert_equal({ "a2a-status" => "working" }, m.user_properties)
    assert_equal 1, m.qos
  end

  def test_unsubscribe_stops_deliveries
    build_transport.connect
    received = []
    sub = @transport.subscribe("runes/flow") { |m| received << m }
    @transport.publish("runes/flow", "first")
    wait_until { received.size == 1 }

    assert_equal true, @transport.unsubscribe(sub)
    @transport.publish("runes/flow", "second")
    sleep 0.2
    assert_equal 1, received.size
    assert_equal false, @transport.unsubscribe(sub), "a second unsubscribe is a no-op"
  end

  def test_disconnect_stops_the_guest_and_cleans_up
    build_transport.connect
    dir = @transport.work_dir
    @transport.subscribe("runes/x") { |m| }

    @transport.disconnect

    refute @transport.connected?
    refute Dir.exist?(dir), "the scratch work dir is removed"
    assert_equal @transport, @transport.disconnect, "disconnect is idempotent"
  end

  def test_connect_is_idempotent_and_double_connect_keeps_subscriptions
    build_transport.connect
    @transport.subscribe("runes/y") { |m| }
    first_dir = @transport.work_dir
    @transport.connect
    assert_equal first_dir, @transport.work_dir
    assert_equal 1, @transport.subscriptions.size
  end

  def test_ops_require_a_connection
    build_transport
    assert_raises(Runes::Transport::Error) { @transport.publish("runes/x", "nope") }
    assert_raises(Runes::Transport::Error) { @transport.subscribe("runes/#") { |m| } }
  end

  def test_publish_validates_topic_and_qos
    build_transport.connect
    assert_raises(Runes::Transport::Error) { @transport.publish("runes/+/bad", "x") }
    assert_raises(Runes::Transport::Error) { @transport.publish("runes/x", "x", qos: 3) }
  end

  def test_transport_build_wires_the_kind
    transport = Runes::Transport.build(kind: "wasi_guest", spawn: cruby_spawn)
    @transport = transport
    transport.connect
    received = []
    transport.subscribe("runes/build") { |m| received << m }
    transport.publish("runes/build", "ok")
    wait_until { received.size == 1 }
    assert_equal "ok", received.first.payload
  end

  def test_a_dead_guest_fails_loudly_on_boot
    boom = lambda do |**_kw|
      raise Runes::Transport::Error, "boom"
    end
    transport = Runes::Transport::WasiGuest.new(spawn: boom)
    err = assert_raises(Runes::Transport::Error) { transport.connect }
    assert_match(/boom/, err.message)
  end

  # The real boundary: ruby.wasm under wasmtime. Opt-in — compiling the
  # 37 MB module takes tens of seconds.
  def test_real_ruby_wasm_guest_end_to_end
    skip "set RUNES_WASM=real to boot the actual ruby.wasm guest" unless ENV["RUNES_WASM"] == "real"

    wasm = File.expand_path("../ruby.wasm", __dir__)
    skip "ruby.wasm not present" unless File.file?(wasm)

    transport = Runes::Transport::WasiGuest.new(wasm_path: wasm, boot_timeout: 120, ack_timeout: 60)
    @transport = transport
    transport.connect
    received = []
    transport.subscribe("runes/wasm") { |m| received << m }
    transport.publish("runes/wasm", "from-the-host")
    wait_until(deadline_s: 30) { received.size == 1 }
    assert_equal "from-the-host", received.first.payload
  end
end
