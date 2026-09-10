# frozen_string_literal: true

require 'json'
require_relative '../core/llm_client'

module Runes
  module LLM
    # Adapter over the community `ruby_llm` gem (crmne/ruby_llm).
    #
    # It exposes the same surface the harness already uses, so it can be
    # selected with `RUNES_LLM_ADAPTER=ruby_llm` and nothing else changes:
    #
    #   #call(prompt, provider:, model:, variation:, tools:)
    #   #chat(messages, system:, json:, variation:, tools:)
    #
    # Both return the harness result hash:
    #   { ok: true, mode: :content,    content:, raw:, provider:, model:, usage:, finish_reason: }
    #   { ok: true, mode: :tool_calls, tool_calls:, raw:, provider:, model:, usage:, finish_reason: }
    #   { ok: false, error: }
    #
    # The gem is NOT a runes dependency and is required lazily (inside
    # .available?), so this file loads — and the registry stays usable — on a
    # machine without it. Selecting it there fails with AdapterUnavailable.
    #
    # Variation mapping (documented because it is lossy):
    #   * temperature: high|max -> 0.7, balanced -> 0.4, low -> 0.2
    #   * effort:      max|ultra -> :max, high|xhigh -> :high, else unset
    #   * `json: true` is NOT translated: ruby_llm expresses structured output
    #     with `with_schema`, and inventing a schema here would be wrong. The
    #     harness planner prompts already ask for strict JSON, and PlanParser
    #     tolerates fences, so this is a prompt-level concern, not a wire one.
    #   * Providers/models that ignore temperature or lack extended thinking
    #     simply drop those knobs (the thinking call is wrapped in a rescue).
    class RubyLLMAdapter
      GEM_NAME = 'ruby_llm'
      # Local copy so this file stays loadable even if required standalone
      # (i.e. before lib/runes/llm.rb defines Runes::LLM::ENV_VAR).
      ADAPTER_ENV = 'RUNES_LLM_ADAPTER'

      # ruby_llm provider slugs we know; everything else in
      # Runes::Core::LLMClient::PROVIDERS is OpenAI-compatible, so we point
      # ruby_llm's :openai provider at its base URL in a per-request context.
      RUBY_LLM_PROVIDERS = { 'deepseek' => :deepseek }.freeze

      TEMPERATURES = { 'high' => 0.7, 'max' => 0.7, 'balanced' => 0.4, 'low' => 0.2 }.freeze
      THINKING_EFFORT = { 'max' => :max, 'ultra' => :max, 'high' => :high, 'xhigh' => :high }.freeze

      # Raised if ruby_llm ever tries to execute a tool: the harness owns
      # execution, and the adapter only asks for tool CALLS (via Chat#generate,
      # which does not run tools). Reaching this means that contract broke.
      class ToolExecutionNotSupported < StandardError; end

      # Settings shim so the built-in prompt builder works when the host
      # passed no settings (routing/db lookups then simply find nothing).
      class DefaultSettings
        def env(_key) = nil
        def get(_key, default = nil) = default
      end

      def self.gem_name
        GEM_NAME
      end

      # Lazy gem probe: never raises, returns false when ruby_llm is absent.
      def self.available?
        require GEM_NAME
        defined?(::RubyLLM) && ::RubyLLM.respond_to?(:chat) ? true : false
      rescue LoadError
        false
      end

      def initialize(settings = nil)
        @settings = settings
      end

      def available?
        self.class.available?
      end

      # Single-turn planning call. Keeps the built-in router's system prompt
      # (tool mode vs. JSON planner) so switching adapters does not change
      # what the model is asked to do.
      def call(prompt, provider: nil, model: nil, variation: nil, tools: nil)
        generate(planner_messages(prompt, tools: tools),
                 system: nil, json: tools.nil?, variation: variation, tools: tools,
                 provider: provider, model: model)
      end

      # Multi-turn conversation (goal/plan modes). Provider/model resolve the
      # same way the built-in router does: env > settings DB > provider default.
      def chat(messages, system: nil, json: false, variation: nil, tools: nil)
        provider = resolve_provider
        generate(messages, system: system, json: json, variation: variation, tools: tools,
                 provider: provider, model: resolve_model(provider))
      end

      private

      def generate(messages, system:, json:, variation:, tools:, provider:, model:)
        require_gem!

        provider = (provider || resolve_provider).to_s
        model    = (model || resolve_model(provider)).to_s

        rchat = build_chat(provider: provider, model: model, variation: variation)
        rchat.with_instructions(system) if system && !system.to_s.empty?
        normalized_messages(messages).each do |m|
          rchat.add_message(role: m[:role], content: m[:content])
        end

        # Schema mapping is independent of `json:`; see the class comment.
        tool_classes = build_tools(tools)
        rchat.with_tools(*tool_classes) unless tool_classes.empty?

        # #generate requests ONE completion and does NOT execute tool calls —
        # exactly the contract the harness wants (it executes them itself).
        message = rchat.generate
        result_from(message, provider: provider, model: model)
      rescue AdapterUnavailable
        raise
      rescue StandardError => e
        { ok: false, error: "ruby_llm adapter: #{e.class}: #{e.message}" }
      end

      def require_gem!
        return true if self.class.available?

        # defined? guard keeps the file standalone-loadable.
        error = defined?(::Runes::LLM::AdapterUnavailable) ? ::Runes::LLM::AdapterUnavailable : ::RuntimeError
        raise error,
              "#{ADAPTER_ENV}=ruby_llm needs the '#{GEM_NAME}' gem, which is not installed. " \
              "Install it (`gem install #{GEM_NAME}`), or unset #{ADAPTER_ENV} to keep the built-in router."
      end

      # --- ruby_llm wiring -------------------------------------------------

      def build_chat(provider:, model:, variation:)
        kwargs = { model: model, provider: ruby_llm_provider(provider), assume_model_exists: true }
        context = build_context(provider)
        kwargs[:context] = context if context

        chat = ::RubyLLM.chat(**kwargs)
        apply_variation(chat, variation)
        chat
      end

      def ruby_llm_provider(provider)
        RUBY_LLM_PROVIDERS[provider.to_s] || :openai
      end

      # Prefer a per-request RubyLLM::Context over global config: the adapter
      # must not mutate process-wide state when the host runs several
      # providers. Falls back to nil (= ruby_llm's own ENV config) on older
      # gem versions or when nothing needs setting.
      def build_context(provider)
        return nil unless ::RubyLLM.respond_to?(:context)

        definition = Core::LLMClient::PROVIDERS[provider.to_s]
        key = api_key_for(definition)
        return nil if definition.nil? && key.nil?

        ::RubyLLM.context do |config|
          if provider.to_s == 'deepseek'
            config.deepseek_api_key = key if key && config.respond_to?(:deepseek_api_key=)
          elsif definition
            # synthetic/cerebras are OpenAI-compatible endpoints.
            config.openai_api_base = definition.base_url if config.respond_to?(:openai_api_base=)
            config.openai_api_key  = key if key && config.respond_to?(:openai_api_key=)
          end
        end
      rescue StandardError
        nil
      end

      def apply_variation(chat, variation)
        v = (variation || setting('RUNES_DEFAULT_VARIATION', 'default_variation', 'high')).to_s.strip.downcase
        v = 'high' if v.empty?

        temp = TEMPERATURES[v]
        chat.with_temperature(temp) if temp && chat.respond_to?(:with_temperature)

        effort = THINKING_EFFORT[v]
        return chat unless effort && chat.respond_to?(:with_thinking)

        begin
          chat.with_thinking(effort: effort)
        rescue StandardError
          nil # model/provider without extended thinking — keep the temperature
        end
        chat
      end

      # OpenAI-style function schema -> RubyLLM::Tool subclass. The tool is a
      # schema carrier only: the harness executes the call, and #generate never
      # invokes #execute. Any execution attempt is a wiring error, loud.
      def build_tools(schemas)
        return [] unless defined?(::RubyLLM::Tool)

        Array(schemas).filter_map { |schema| build_tool(schema) }
      end

      def build_tool(schema)
        fn = schema[:function] || schema['function'] || {}
        fn_name = fn[:name] || fn['name']
        return nil if fn_name.nil? || fn_name.to_s.empty?

        description = fn[:description] || fn['description']
        parameters  = fn[:parameters] || fn['parameters'] || { 'type' => 'object', 'properties' => {} }

        tool = Class.new(::RubyLLM::Tool)
        tool.define_singleton_method(:tool_name) { fn_name.to_s }
        tool.description(description.to_s) if description && !description.to_s.empty?
        tool.parameters(parameters) if tool.respond_to?(:parameters)
        tool.define_method(:execute) do |**args|
          raise ToolExecutionNotSupported,
                "runes executes tool calls itself; ruby_llm must not run '#{fn_name}' (args: #{args.inspect})"
        end
        tool
      rescue StandardError
        nil
      end

      # --- harness result mapping ------------------------------------------

      def result_from(message, provider:, model:)
        calls = message.respond_to?(:tool_calls) ? message.tool_calls : nil
        if calls && !calls.empty?
          return {
            ok: true, mode: :tool_calls,
            tool_calls: calls.map { |id, call| tool_call_hash(id, call) },
            raw: raw_of(message), provider: provider, model: model,
            usage: usage_of(message), finish_reason: finish_of(message)
          }
        end

        content = message.respond_to?(:content) ? message.content : nil
        return { ok: false, error: 'ruby_llm response has neither content nor tool_calls' } if content.nil?

        {
          ok: true, mode: :content, content: content,
          raw: raw_of(message), provider: provider, model: model,
          usage: usage_of(message), finish_reason: finish_of(message)
        }
      end

      def tool_call_hash(id, call)
        {
          id: call.respond_to?(:id) ? call.id : id,
          tool: call.respond_to?(:name) ? call.name : nil,
          args: (call.respond_to?(:arguments) ? call.arguments : nil) || {}
        }
      end

      # ruby_llm exposes the provider body on Message#raw (a Faraday::Response
      # or a Hash). Prefer a Hash — the built-in router's `raw:` is parsed JSON.
      def raw_of(message)
        raw = message.respond_to?(:raw) ? message.raw : nil
        return raw if raw.is_a?(Hash)

        body = raw.respond_to?(:body) ? raw.body : nil
        return JSON.parse(body) if body.is_a?(String) && !body.empty?

        raw
      rescue StandardError
        nil
      end

      def usage_of(message)
        tokens = message.respond_to?(:tokens) ? message.tokens : nil
        return nil if tokens.nil?

        input  = tokens.respond_to?(:input) ? tokens.input : nil
        output = tokens.respond_to?(:output) ? tokens.output : nil
        total  = tokens.respond_to?(:total) ? tokens.total : nil
        total ||= input.to_i + output.to_i if input || output
        # String keys mirror the built-in router's raw provider usage hash;
        # symbol aliases keep embedders that read the harness contract happy.
        { 'prompt_tokens' => input, 'completion_tokens' => output, 'total_tokens' => total,
          input_tokens: input, output_tokens: output }.compact
      rescue StandardError
        nil
      end

      def finish_of(message)
        message.respond_to?(:finish_reason) ? message.finish_reason&.to_s : nil
      end

      # --- routing / settings ----------------------------------------------

      def planner_messages(prompt, tools:)
        router = Core::LLMClient.new(@settings.respond_to?(:env) ? @settings : DefaultSettings.new)
        route = Core::LLMClient::Route.new(provider: GEM_NAME, model: GEM_NAME, sampling_params: {})
        payload = router.build_payload(route, prompt, tools: tools, json: tools.nil?)
        payload[:messages].map { |m| { role: m['role'], content: m['content'] } }
      rescue StandardError
        # If the built-in request builder changes shape, degrade to the plain
        # user turn rather than failing the call.
        normalized_messages(prompt)
      end

      def normalized_messages(messages)
        Array(messages).filter_map do |m|
          if m.is_a?(Hash)
            content = m[:content] || m['content']
            next if content.nil?

            { role: (m[:role] || m['role'] || 'user').to_s, content: content.to_s }
          else
            { role: 'user', content: m.to_s }
          end
        end
      end

      def resolve_provider
        name = setting('RUNES_DEFAULT_PROVIDER', 'default_provider', nil).to_s.strip.downcase
        return name unless name.empty?

        Core::LLMClient::PROVIDER_PREFERENCE.first
      end

      def resolve_model(provider)
        explicit = setting('RUNES_DEFAULT_MODEL', 'default_model', nil).to_s.strip
        return explicit unless explicit.empty?

        definition = Core::LLMClient::PROVIDERS[provider.to_s]
        definition&.default_model || provider.to_s
      end

      # env > settings DB > default, tolerating a nil/ghetto settings object.
      def setting(env_key, db_key, default = nil)
        if @settings.respond_to?(:env)
          value = @settings.env(env_key)
          return value if value && !value.to_s.strip.empty?
        end
        if @settings.respond_to?(:get)
          value = @settings.get(db_key)
          return value if value && !value.to_s.strip.empty?
        end
        default
      end

      def api_key_for(definition)
        return nil unless definition && @settings.respond_to?(:env)

        definition.key_envs.filter_map { |env| @settings.env(env) }
                  .find { |value| value && !value.to_s.strip.empty? }
      end
    end
  end
end
