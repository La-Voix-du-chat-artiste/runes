require 'json'
require 'open3'
require 'thread'
require 'timeout'
require_relative 'protocol'

module Runes
  module MCP
    # MCP client: spawns (or attaches to) a server subprocess and speaks
    # newline-delimited JSON-RPC 2.0 over its stdin/stdout.
    #
    # Threading model:
    #   * a READER thread owns the child's stdout and dispatches each message
    #     to the caller waiting on its JSON-RPC id;
    #   * a STDERR drain thread owns the child's stderr — a server that logs
    #     verbosely must not fill the pipe and deadlock the process;
    #   * callers block on their own Queue with a deadline, so one hung
    #     request cannot take the whole client down.
    #
    # Unsolicited responses (an id we never sent) are rejected and logged,
    # never matched to whatever caller happens to be waiting: matching by id
    # is the entire correctness property of a JSON-RPC client.
    class Client
      DEFAULT_TIMEOUT_S = 30.0
      STDOUT_BUFFER_BYTES = 1 * 1024 * 1024
      # A child that ignores stdin-close gets this long to exit before SIGKILL.
      # Short on purpose: a healthy server exits on EOF immediately, and the
      # only callers that pay this are ones already stuck.
      KILL_GRACE_S = 0.5

      attr_reader :command, :args, :name, :version, :stderr_lines

      def initialize(command:, args: [], env: {}, name: 'runes', version: '0.0.0',
                     timeout_s: DEFAULT_TIMEOUT_S)
        @command = command
        @args = Array(args)
        @env = env || {}
        @name = name
        @version = version
        @timeout_s = Float(timeout_s)
        @pending = {}          # id => Queue
        @start_mutex = Mutex.new
        @pending_mutex = Mutex.new
        @write_mutex = Mutex.new
        @id_mutex = Mutex.new
        @next_id = 0
        @stderr_lines = []
        @stderr_mutex = Mutex.new
        @closed = false
        @stdin = @stdout = @wait_thread = nil
        @reader = @stderr_reader = nil
      end

      def open?
        !@closed && !@stdin.nil? && !@stdin.closed?
      end

      # Spawn the server and start the reader/drain threads. Idempotent:
      # calling #start on a live client is a no-op so `#start` can be used
      # lazily inside tools/call_tool.
      def start
        # Double-checked under a mutex: two threads calling #request on a
        # fresh client used to spawn TWO servers and leak the first one,
        # whose stdin/stdout were then overwritten (doc5.md T5-10).
        @start_mutex.synchronize do
          return self if open?

          @stdin, @stdout, stderr, @wait_thread = Open3.popen3(@env, @command, *@args)
          @stdout.binmode
          @stderr_reader = Thread.new { drain_stderr(stderr) }
          @stderr_reader.name = 'runes-mcp-stderr' if @stderr_reader.respond_to?(:name=)
          @reader = Thread.new { read_loop }
          @reader.name = 'runes-mcp-reader' if @reader.respond_to?(:name=)
        end
        self
      end

      # MCP handshake. Returns the server's initialize result.
      def initialize_session
        start
        result = request('initialize', {
                           'protocolVersion' => Protocol::LATEST_VERSION,
                           'capabilities' => {},
                           'clientInfo' => { 'name' => @name, 'version' => @version }
                         })
        notify('notifications/initialized')
        result
      end

      # `tools/list` -> the server's descriptor array, defensively filtered
      # so a malformed entry cannot poison the caller.
      def tools
        result = request('tools/list', {})
        list = result.is_a?(Hash) ? result['tools'] : nil
        Array(list).select { |tool| tool.is_a?(Hash) && !tool['name'].to_s.empty? }
      end

      # `tools/call` -> the raw MCP result Hash.
      # `timeout:` bounds THIS call only, which matters because the client's
      # construction timeout also covers the startup handshake: a test that
      # wants to prove a hanging tool times out must not also race the
      # handshake against it (doc5.md D5-3).
      def call_tool(name, args = {}, timeout: @timeout_s)
        request('tools/call', { 'name' => name, 'arguments' => args || {} }, timeout: timeout)
      end

      # Send a JSON-RPC request and block until its response arrives.
      def request(method, params = {}, timeout: @timeout_s)
        raise IOError, 'MCP client is closed' if @closed

        start unless open?
        id = next_id
        waiter = Queue.new
        @pending_mutex.synchronize { @pending[id] = waiter }
        begin
          write_message('jsonrpc' => Protocol::JSONRPC_VERSION, 'id' => id,
                        'method' => method, 'params' => params)
          message = wait_for(waiter, id, timeout)
        ensure
          @pending_mutex.synchronize { @pending.delete(id) }
        end

        if message['error'].is_a?(Hash)
          raise Error.new(message['error']['code'], message['error']['message'], message['error']['data'])
        end
        message['result']
      end

      # Fire-and-forget notification (no id, no response expected).
      def notify(method, params = {})
        start unless open?
        write_message('jsonrpc' => Protocol::JSONRPC_VERSION, 'method' => method, 'params' => params)
        nil
      end

      # A protocol-level error object from the server, surfaced as an
      # exception so callers only deal with results on the happy path.
      class Error < StandardError
        def initialize(code, message, data = nil)
          @code = code
          @data = data
          super("MCP error #{code}: #{message}")
        end

        attr_reader :code, :data
      end

      # Close stdin (EOF makes a well-behaved server exit), wait briefly, then
      # force-kill. Joins the helper threads so callers can assert cleanup.
      def close
        return if @closed

        @closed = true
        # A pipe that closed cleanly means the peer saw EOF/EPIPE: kill it
        # outright instead of waiting out the grace period on a server that
        # is already blocked (e.g. a wedged tool call).
        graceful = close_stdin
        terminate_child(graceful)
        fail_pending(Error.new(Protocol::INTERNAL_ERROR, 'client closed'))
        @reader&.join(1)
        @stderr_reader&.join(1)
        @stdout&.close unless @stdout.nil? || @stdout.closed?
        @stdin = @stdout = @wait_thread = nil
        nil
      rescue IOError, Errno::EPIPE, Errno::EBADF
        nil
      end

      def closed?
        @closed
      end

      # Diagnostics: the last thing the child wrote to stderr (bounded).
      def stderr_tail(bytes = 2000)
        text = @stderr_mutex.synchronize { @stderr_lines.join("\n") }
        # String#[-n..] returns nil when the string is shorter than n, so
        # slice explicitly instead of relying on negative beginless ranges.
        text.bytesize > bytes ? text.byteslice(text.bytesize - bytes, bytes).to_s : text
      end

      private

      def next_id
        @id_mutex.synchronize { @next_id += 1 }
      end

      def write_message(message)
        line = Protocol.encode(message)
        @write_mutex.synchronize do
          raise IOError, 'MCP client is closed' if @stdin.nil? || @stdin.closed?

          @stdin.write(line)
          @stdin.write("\n")
          @stdin.flush
        end
      rescue Errno::EPIPE, Errno::EBADF => e
        @closed = true
        raise IOError, "MCP server is gone (#{e.class}: #{e.message})"
      end

      def wait_for(waiter, id, timeout_s)
        deadline = monotonic + timeout_s
        loop do
          remaining = deadline - monotonic
          if remaining <= 0
            raise Timeout::Error,
                  "MCP request id=#{id} timed out after #{timeout_s}s" \
                  "#{stderr_tail.empty? ? '' : " (server stderr: #{stderr_tail(400)})"}"
          end

          begin
            return waiter.pop(true) # non-blocking probe
          rescue ThreadError
            sleep [remaining, 0.01].min
          end
        end
      end

      # Owns stdout. EOF means the server is gone: fail every waiter with a
      # clear error instead of letting them time out one by one.
      def read_loop
        loop do
          # gets(limit) returns the over-long line in bounded pieces, so a
          # peer that streams bytes without a newline cannot grow this
          # process's buffer without limit (doc5.md T5-11).
          line = @stdout.gets(STDOUT_BUFFER_BYTES + 1)
          break if line.nil?
          if line.bytesize > STDOUT_BUFFER_BYTES
            fail_pending(Error.new(Protocol::INTERNAL_ERROR, 'MCP server sent an oversized line'))
            break
          end

          handle_line(line)
        end
      rescue IOError, Errno::EBADF
        nil
      ensure
        fail_pending(Error.new(Protocol::INTERNAL_ERROR, 'MCP server closed the connection')) unless @closed
      end

      def handle_line(line)
        line = line.to_s.strip
        return if line.empty?

        message = Protocol.decode(line)
        if message.nil?
          warn "[MCP] malformed line from server: #{line[0, 120]}"
          return
        end

        id = message['id']
        waiter = @pending_mutex.synchronize { @pending[id] }
        if waiter.nil?
          # Either a notification or a response to an id we never sent. The
          # latter is a protocol violation — drop it loudly rather than
          # handing it to an unrelated caller.
          warn "[MCP] ignoring response for unsolicited id #{id.inspect}" if message.key?('id')
          return
        end

        waiter << message
      end

      # Owns stderr: unbounded pipes deadlock the child, so always drain.
      def drain_stderr(io)
        while (line = io.gets)
          @stderr_mutex.synchronize do
            @stderr_lines << line.chomp
            @stderr_lines.shift while @stderr_lines.size > 200
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def fail_pending(error)
        @pending_mutex.synchronize do
          @pending.each_value { |waiter| waiter << { 'error' => { 'code' => error.code, 'message' => error.message } } }
        end
      end

      # True when stdin was already unusable (server gone/pipe broken).
      def close_stdin
        @stdin&.close unless @stdin.nil? || @stdin.closed?
        false
      rescue IOError, Errno::EPIPE
        true
      end

      def terminate_child(skip_grace)
        return if @wait_thread.nil?
        return if !skip_grace && @wait_thread.join(KILL_GRACE_S)

        # The server ignored EOF. Kill its whole process group when we can
        # (Open3.popen3 has no pgroup option, so fall back to the pid) so a
        # spawned server with children cannot leak.
        pid = @wait_thread.pid
        begin
          Process.kill('KILL', -pid)
        rescue StandardError
          begin
            Process.kill('KILL', pid)
          rescue StandardError
            nil
          end
        end
        @wait_thread.join(1)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
