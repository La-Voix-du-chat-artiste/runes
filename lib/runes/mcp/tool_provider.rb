require 'json'
require_relative 'protocol'

module Runes
  module MCP
    # The seam between the harness and MCP.
    #
    # A provider is anything that responds to:
    #   #tool_descriptors               -> [{"name"=>, "description"=>, "inputSchema"=>{...}}]
    #   #call_tool(name, args)          -> {"content"=>[{"type"=>"text","text"=>...}], "isError"=>bool}
    #
    # This class makes that contract forgiving so the harness's existing
    # descriptor shapes (OpenAI-style `function:` schemas, symbol keys) and
    # plain-string tool results can be plugged in without an adapter class:
    #
    #   * the production path wraps a "source" object (the dispatcher-facing
    #     adapter) and normalizes whatever it returns;
    #   * `from_lists` builds a provider straight from arrays/blocks so the
    #     server and client can be exercised in tests without a harness.
    #
    # Tool failures (unknown tool, guard denial, executor exception) are
    # raised as ToolCallError so the SERVER can turn them into an MCP error
    # result. They are never allowed to escape as protocol-level crashes.
    class ToolCallError < StandardError; end

    class ToolProvider
      # Every text block is capped so a chatty tool cannot produce a
      # multi-megabyte MCP frame (or blow up the caller's context window).
      DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024

      def initialize(source: nil, tools: nil, callable: nil, max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES)
        raise ArgumentError, 'source (or tools:) is required' if source.nil? && tools.nil?

        @source = source
        @max_output_bytes = Integer(max_output_bytes)
        list = tools || source.tool_descriptors
        @tools = Array(list).map { |card| normalize_descriptor(card) }.freeze
        @by_name = @tools.each_with_object({}) { |card, h| h[card['name']] = card }.freeze
        # `callable` is the test seam: one object that implements the whole
        # call surface. Without it we delegate back to the wrapped source.
        @callable = callable
      end

      # Test/embed helper: no harness required.
      #   ToolProvider.from_lists(tools: [...], callable: ->(name, args) { "text" })
      def self.from_lists(tools:, callable:, **options)
        new(tools: tools, callable: callable, **options)
      end

      attr_reader :tools, :max_output_bytes

      def tool_descriptors
        @tools
      end

      # MCP `tools/list` payload (the spec nests descriptors under "tools").
      def list_payload
        { 'tools' => @tools }
      end

      def names
        @by_name.keys
      end

      def known?(name)
        @by_name.key?(name.to_s)
      end

      # Always returns an MCP call result Hash. Unknown tools and executor
      # failures become `isError` results — this method never raises, so the
      # server's happy path stays trivial.
      def call(name, args)
        name = name.to_s
        args = {} unless args.is_a?(Hash)

        unless known?(name)
          return error_result("Error: unknown tool #{name} (known: #{names.sort.join(', ')})")
        end

        raw = begin
          @callable ? @callable.call(name, args) : call_source(name, args)
        rescue ToolCallError => e
          return error_result(e.message)
        rescue StandardError => e
          return error_result("Error: tool #{name} failed: #{e.class}: #{e.message}")
        end

        normalize_result(raw)
      end

      # Alias so a provider can be used directly as the harness's
      # `#call_tool` implementation.
      alias call_tool call

      private

      def call_source(name, args)
        unless @source.respond_to?(:call_tool)
          raise ToolCallError, "Error: provider source cannot execute tool #{name}"
        end

        @source.call_tool(name, args)
      end

      # Accept every shape the harness might hand us:
      #   * already-MCP: {"content"=>[...], "isError"=>bool}
      #   * a bare String (the dispatcher's executors return strings)
      #   * a Hash with symbol keys
      #   * nil (tool produced no output)
      def normalize_result(raw)
        case raw
        when Hash
          content = raw['content'] || raw[:content]
          if content.is_a?(Array)
            {
              'content' => content.map { |block| normalize_content_block(block) },
              'isError' => truthy?(raw['isError'] || raw[:isError])
            }
          else
            text_result(raw['text'] || raw[:text] || JSON.generate(raw))
          end
        when nil
          text_result('')
        when String
          # The dispatcher's executors report failure by RETURNING an
          # "Error: ..." string, so a bare string is only a success when it
          # does not carry that prefix. Without this, a guard denial would
          # reach the client as isError=false.
          string_result(raw)
        else
          text_result(raw.to_s)
        end
      end

      def normalize_content_block(block)
        return { 'type' => 'text', 'text' => truncate(block.to_s) } unless block.is_a?(Hash)

        type = (block['type'] || block[:type] || 'text').to_s
        if type == 'text'
          text = block.key?('text') ? block['text'] : block[:text]
          { 'type' => 'text', 'text' => truncate(text.to_s) }
        else
          # Non-text blocks are passed through untouched (and un-capped):
          # they are opaque to us, and guessing at their size is worse than
          # letting the caller see exactly what the tool returned.
          block
        end
      end

      def text_result(text)
        { 'content' => [{ 'type' => 'text', 'text' => truncate(text.to_s) }], 'isError' => false }
      end

      # "Error: ..." is the harness's failure prefix (Dispatcher#execute_builtin,
      # execute_manifest_tool, execute_step all use it).
      def string_result(text)
        text = text.to_s
        result = text_result(text)
        result['isError'] = true if text.start_with?('Error:')
        result
      end

      def error_result(message)
        { 'content' => [{ 'type' => 'text', 'text' => truncate(message.to_s) }], 'isError' => true }
      end

      def truncate(text)
        Protocol.truncate_bytes(text, @max_output_bytes)
      end

      # Accepts the MCP shape, the OpenAI function-tool shape the harness
      # already produces, or a minimal card. The MCP list must be uniform, so
      # normalization happens once here rather than at every call site.
      def normalize_descriptor(card)
        raise ArgumentError, "tool descriptor must be a Hash, got #{card.class}" unless card.is_a?(Hash)

        fn = card['function'] || card[:function]
        name = fetch(card, 'name') || (fn.is_a?(Hash) ? fetch(fn, 'name') : nil)
        raise ArgumentError, 'tool descriptor is missing a name' if name.to_s.empty?

        description = fetch(card, 'description') || (fn.is_a?(Hash) ? fetch(fn, 'description') : nil)
        schema = fetch(card, 'inputSchema') || fetch(card, 'parameters') ||
                 (fn.is_a?(Hash) ? (fetch(fn, 'parameters') || fetch(fn, 'inputSchema')) : nil)

        {
          'name' => name.to_s,
          'description' => description.to_s,
          'inputSchema' => schema.is_a?(Hash) ? schema : { 'type' => 'object', 'properties' => {} }
        }
      end

      def fetch(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_sym]
      end

      def truthy?(value)
        value == true || value.to_s.downcase == 'true'
      end
    end
  end
end
