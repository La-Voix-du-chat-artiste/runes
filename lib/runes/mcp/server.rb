require 'json'
require_relative 'protocol'

module Runes
  module MCP
    # MCP server over stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout.
    #
    # The reader loop is deliberately single-threaded and sequential: MCP's
    # stdio transport has no request pipelining requirement, and serial
    # handling means a slow tool call cannot interleave two responses. Writes
    # are mutex-guarded anyway, because notifications (which produce no
    # response) may be handled while a response is being written.
    #
    # Every diagnostic goes to stderr: stdout is the protocol channel, and a
    # stray `puts` is indistinguishable from a malformed server message.
    #
    # Testability: pass `io:` (an object with #gets/#write/#flush) to drive
    # the server over StringIO, or `input:`/#output:` separately. Defaults are
    # the real $stdin/$stdout — i.e. no injection needed in production.
    class Server
      # Methods a request may legally name. Anything else is -32601.
      REQUEST_METHODS = %w[
        initialize ping tools/list tools/call
      ].freeze
      NOTIFICATION_METHODS = %w[notifications/initialized notifications/cancelled].freeze

      def initialize(provider:, io: nil, input: nil, output: nil,
                     name: Protocol::SERVER_NAME, version: Protocol::SERVER_VERSION,
                     logger: nil)
        @provider = provider
        @input = input || (io.respond_to?(:gets) ? io : $stdin)
        @output = output || (io.respond_to?(:write) ? io : $stdout)
        @name = name
        @version = version
        @logger = logger
        @write_mutex = Mutex.new
        @stopped = false
      end

      # Read/answer until EOF (client closed stdin) or #stop. One malformed
      # line must never end the session — the loop keeps serving.
      def serve
        until @stopped
          # Bounded read: `gets` with a limit returns an over-long line in
          # pieces, so a newline-less flood cannot balloon the buffer before
          # the size check in #handle_line runs (doc5.md T5-11).
          line = read_line
          break if line.nil? # EOF: client is done

          handle_line(line)
        end
        log 'stdin closed; server loop exiting'
      end

      def stop
        @stopped = true
      end

      # Bounded where the reader supports it; an injected duck-typed reader
      # (tests, embedders) may only implement a bare #gets.
      def read_line
        @input.gets(Protocol::MAX_MESSAGE_BYTES + 1)
      rescue ArgumentError
        @input.gets
      end

      # Exposed for tests and for embedders that own their own read loop.
      def handle_line(line)
        line = line.to_s
        return nil if line.strip.empty?

        if line.bytesize > Protocol::MAX_MESSAGE_BYTES
          send_message(Protocol.error_response(nil, Protocol::INVALID_REQUEST,
                                               'message too large'))
          return nil
        end

        message = Protocol.decode(line)
        if message.nil?
          # Malformed JSON carries no usable id — reply with null per spec.
          send_message(Protocol.error_response(nil, Protocol::PARSE_ERROR))
          return nil
        end

        dispatch(message)
      end

      # Routes one decoded message. Returns the response Hash (also written
      # to the output stream) or nil for notifications.
      def dispatch(message)
        unless Protocol.request?(message)
          handle_notification(message)
          return nil
        end

        response = begin
          dispatch_request(message)
        rescue Protocol::Error => e
          Protocol.error_response(message['id'], e.code, e.message, e.data)
        rescue StandardError => e
          # A bug in a handler must not kill the session or leak a backtrace
          # to the peer — log it and answer with a generic internal error.
          log "[MCP] handler error for #{message['method']}: #{e.class}: #{e.message}"
          Protocol.error_response(message['id'], Protocol::INTERNAL_ERROR, e.message)
        end
        send_message(response) if response
        response
      end

      private

      def dispatch_request(message)
        method = message['method'].to_s
        params = message['params']
        params = {} unless params.is_a?(Hash)

        case method
        when 'initialize'          then handle_initialize(message['id'], params)
        when 'ping'                then Protocol.response(message['id'], {})
        when 'tools/list'          then Protocol.response(message['id'], @provider.list_payload)
        when 'tools/call'          then handle_tools_call(message['id'], params)
        else
          Protocol.error_response(message['id'], Protocol::METHOD_NOT_FOUND,
                                  "Method not found: #{method}")
        end
      end

      def handle_notification(message)
        method = message['method'].to_s
        log "[MCP] notification #{method}" if method == 'notifications/initialized'
        # Unknown notifications are ignored on purpose (spec: never answer a
        # notification, and never error one either).
        nil
      end

      def handle_initialize(id, params)
        client_info = params['clientInfo'].is_a?(Hash) ? params['clientInfo'] : {}
        log "[MCP] initialize from #{client_info['name'] || 'unknown'} " \
            "#{client_info['version']} (protocol=#{params['protocolVersion']})"
        Protocol.response(id, {
                            'protocolVersion' => Protocol.negotiate_version(params['protocolVersion']),
                            'capabilities' => { 'tools' => {} },
                            'serverInfo' => { 'name' => @name, 'version' => @version }
                          })
      end

      def handle_tools_call(id, params)
        name = params['name'].to_s
        if name.empty?
          return Protocol.error_response(id, Protocol::INVALID_PARAMS,
                                         'tools/call requires a tool name')
        end

        args = params['arguments'] || params['args']
        args = {} if args.nil?
        unless args.is_a?(Hash)
          return Protocol.error_response(id, Protocol::INVALID_PARAMS,
                                         'tools/call arguments must be an object')
        end

        # Tool-level failure (unknown tool, guard denial, executor crash)
        # is an MCP *result* with isError, not a JSON-RPC error: the client
        # asked a valid question and deserves a readable answer.
        result = @provider.call(name, args)
        Protocol.response(id, result)
      rescue Protocol::Error => e
        Protocol.error_response(id, e.code, e.message, e.data)
      rescue StandardError => e
        log "[MCP] tools/call #{name} crashed: #{e.class}: #{e.message}"
        Protocol.response(id, {
                            'content' => [{ 'type' => 'text', 'text' => "Error: #{e.message}" }],
                            'isError' => true
                          })
      end

      def send_message(message)
        line = Protocol.encode(message)
        @write_mutex.synchronize do
          @output.write(line)
          @output.write("\n")
          @output.flush if @output.respond_to?(:flush)
        end
      rescue IOError, Errno::EPIPE => e
        log "[MCP] write failed (#{e.class}: #{e.message}); stopping"
        @stopped = true
      end

      def log(message)
        return unless @logger

        @logger.call(message)
      rescue StandardError
        nil
      end
    end
  end
end
