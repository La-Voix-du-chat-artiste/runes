require 'json'

module Runes
  module MCP
    # JSON-RPC 2.0 + Model Context Protocol framing/version helpers.
    #
    # MCP over stdio is newline-delimited JSON: one complete JSON value per
    # line, no Content-Length framing (that variant belongs to the HTTP/SSE
    # transports). Everything here is stdlib-only and side-effect free so the
    # server, the client, the provider seam and the tests all share ONE
    # definition of what a message looks like.
    #
    # Why hand-rolled rather than a gem: the project is stdlib-only, and the
    # wire surface we need (five methods + error codes) is small enough that
    # a dependency would buy nothing.
    module Protocol
      # Protocol revisions we know how to speak, newest first. The server
      # echoes the client's requested revision only when it is on this list
      # (never blindly: a client asking for a future revision must be told
      # what we actually speak).
      SUPPORTED_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
      LATEST_VERSION = SUPPORTED_VERSIONS.first

      # JSON-RPC 2.0 reserved error codes.
      PARSE_ERROR      = -32_700
      INVALID_REQUEST  = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS   = -32_602
      INTERNAL_ERROR   = -32_603

      ERROR_MESSAGES = {
        PARSE_ERROR      => 'Parse error',
        INVALID_REQUEST  => 'Invalid Request',
        METHOD_NOT_FOUND => 'Method not found',
        INVALID_PARAMS   => 'Invalid params',
        INTERNAL_ERROR   => 'Internal error'
      }.freeze

      # A single protocol line that exceeds this is rejected instead of
      # buffered forever: a hostile/broken peer must not be able to grow the
      # process by streaming one unbounded "line".
      MAX_MESSAGE_BYTES = 8 * 1024 * 1024
      JSONRPC_VERSION = '2.0'.freeze
      SERVER_NAME = 'runes-mcp'.freeze
      SERVER_VERSION = '0.1.0'.freeze

      # Raised by callers that want a protocol-level failure surfaced as a
      # JSON-RPC error object rather than an MCP tool result.
      class Error < StandardError
        def initialize(code = INTERNAL_ERROR, message = nil, data = nil)
          super(message || ERROR_MESSAGES[code] || 'error')
          @code = code
          @data = data
        end

        attr_reader :code, :data
      end

      module_function

      def encode(message)
        JSON.generate(message)
      end

      # Permissive by design: the transport reads a line, this decides whether
      # it is a usable request. Returns nil for malformed JSON or for a value
      # that is not a JSON object (arrays/scalars cannot be JSON-RPC).
      def decode(line)
        parsed = JSON.parse(line.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError, EncodingError, ArgumentError
        nil
      end

      def response(id, result)
        { 'jsonrpc' => JSONRPC_VERSION, 'id' => id, 'result' => result }
      end

      def error_response(id, code, message = nil, data = nil)
        error = { 'code' => code, 'message' => message || ERROR_MESSAGES[code] || 'error' }
        error['data'] = data unless data.nil?
        { 'jsonrpc' => JSONRPC_VERSION, 'id' => id, 'error' => error }
      end

      # Distinguishes a request (has "id") from a notification (no "id").
      # `id: null` is an explicit (if unusual) request id and must still be
      # answered, so presence of the key — not its truthiness — decides.
      def request?(message)
        message.is_a?(Hash) && message.key?('id')
      end

      # Prefer the client's requested revision when we support it; otherwise
      # advertise our newest so the client can decide to downgrade or bail.
      def negotiate_version(requested)
        requested = requested.to_s
        return requested if SUPPORTED_VERSIONS.include?(requested)

        LATEST_VERSION
      end

      # UTF-8-safe byte truncation; the explicit marker keeps a capped result
      # from masquerading as a complete one.
      def truncate_bytes(text, limit)
        str = text.to_s
        return str if limit <= 0 || str.bytesize <= limit

        str.byteslice(0, limit).to_s.scrub + "…[truncated #{str.bytesize - limit}B]"
      end
    end
  end
end
