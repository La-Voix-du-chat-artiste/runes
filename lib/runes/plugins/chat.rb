# frozen_string_literal: true

require_relative "../rune"
require_relative "../workflow/util"
require_relative "../core/llm_client"

module Runes
  module Plugins
    # The `chat` rune: prompt a cloud LLM and read back the response.
    #
    # Roast's provider names, environment variables and default models are
    # preserved, but the HTTP call goes through a backend seam
    # (`Runes::Plugins::Chat.backend=`). The default backend routes through
    # Runes' own `Core::LLMClient` (whatever provider has a key); when
    # `RUNES_LLM_ADAPTER=ruby_llm` and the gem is present, the ruby_llm adapter
    # is used instead. Tests inject a fake backend, so no network is touched.
    class Chat < Runes::Rune
      plugin :chat, description: "Prompt a cloud LLM"

      class MaxTokensExceededError < Runes::Error; end

      # Conversation state that can be carried between chat runes.
      class Session
        class << self
          def from_chat(chat)
            messages = chat.respond_to?(:messages) ? Runes.deep_dup(chat.messages) : []
            new(messages)
          end
        end

        attr_reader :messages

        def initialize(messages = [])
          @messages = messages
        end

        def first(count = 2)
          self.class.new(Runes.deep_dup(@messages.first(count)))
        end

        def last(count = 2)
          self.class.new(Runes.deep_dup(@messages.last(count)))
        end

        def apply!(chat)
          if chat.respond_to?(:messages=)
            chat.messages = Runes.deep_dup(@messages)
          else
            chat.instance_variable_set(:@messages, Runes.deep_dup(@messages))
          end
          chat
        end

        def ==(other)
          other.is_a?(Session) && other.messages == messages
        end
      end

      # What a backend returns.
      Reply = Struct.new(:response, :messages, :model, :input_tokens, :output_tokens, keyword_init: true)

      class Config < Runes::Cog::Config
        DEFAULT_PROVIDER_ENV_VAR = "ROAST_DEFAULT_CHAT_PROVIDER"

        PROVIDERS = {
          openai: {
            api_key_env_var: "OPENAI_API_KEY",
            base_url_env_var: "OPENAI_API_BASE",
            default_base_url: "https://api.openai.com/v1",
            default_model: "gpt-4o-mini"
          },
          anthropic: {
            api_key_env_var: "ANTHROPIC_API_KEY",
            base_url_env_var: "ANTHROPIC_API_BASE",
            default_base_url: "https://api.anthropic.com",
            default_model: "claude-haiku-4-5"
          },
          perplexity: {
            api_key_env_var: "PERPLEXITY_API_KEY",
            default_model: "sonar"
          },
          gemini: {
            api_key_env_var: "GEMINI_API_KEY",
            base_url_env_var: "GEMINI_API_BASE",
            default_base_url: "https://generativelanguage.googleapis.com/v1beta",
            default_model: "gemini-3.1-flash-lite"
          }
        }.freeze

        def provider(provider)
          @values[:provider] = provider
        end

        def use_default_provider!
          @values[:provider] = nil
        end

        def valid_provider!
          env_default = Runes.presence(ENV[DEFAULT_PROVIDER_ENV_VAR])&.strip&.downcase&.to_sym
          provider = @values[:provider] || env_default || PROVIDERS.keys.first
          unless PROVIDERS.include?(provider)
            raise InvalidConfigError,
                  "'#{provider}' is not a valid provider. Available providers include: #{PROVIDERS.keys.join(', ')}"
          end

          provider
        end

        def api_key(key)
          @values[:api_key] = key
        end

        def use_api_key_from_environment!
          @values.delete(:api_key)
        end

        def valid_api_key!
          value = @values.fetch(:api_key, ENV[PROVIDERS.dig(valid_provider!, :api_key_env_var)])
          raise InvalidConfigError, "no api key provided" unless value

          value
        end

        def base_url(url)
          @values[:base_url] = url
        end

        def use_default_base_url!
          @values[:base_url] = nil
        end

        def valid_base_url
          env_var = PROVIDERS.dig(valid_provider!, :base_url_env_var)
          @values.fetch(:base_url, env_var && ENV[env_var]) || PROVIDERS.dig(valid_provider!, :default_base_url)
        end

        def model(model)
          @values[:model] = model
        end

        def use_default_model!
          @values.delete(:model)
        end

        def valid_model
          @values.fetch(:model, PROVIDERS.dig(valid_provider!, :default_model))
        end

        def temperature(value)
          if value < 0.0 || value > 1.0
            raise ArgumentError, "temperature must be between 0.0 and 1.0, got #{value}"
          end

          @values[:temperature] = value.to_f
        end

        def use_default_temperature!
          @values.delete(:temperature)
        end

        def valid_temperature
          @values[:temperature]
        end

        def verify_model_exists!
          @values[:verify_model_exists] = true
        end

        def no_verify_model_exists!
          @values[:verify_model_exists] = false
        end

        def verify_model_exists?
          @values.fetch(:verify_model_exists, false)
        end

        def show_prompt!
          @values[:show_prompt] = true
        end

        def no_show_prompt!
          @values[:show_prompt] = false
        end

        def show_prompt?
          @values.fetch(:show_prompt, false)
        end

        def show_response!
          @values[:show_response] = true
        end

        def no_show_response!
          @values[:show_response] = false
        end

        def show_response?
          @values.fetch(:show_response, true)
        end

        def show_stats!
          @values[:show_stats] = true
        end

        def no_show_stats!
          @values[:show_stats] = false
        end

        def show_stats?
          @values.fetch(:show_stats, true)
        end

        def display!
          show_prompt!
          show_response!
          show_stats!
        end

        def no_display!
          no_show_prompt!
          no_show_response!
          no_show_stats!
        end

        def display?
          show_prompt? || show_response? || show_stats?
        end

        alias quiet! no_display!
        alias assume_model_exists! no_verify_model_exists!
      end

      class Input < Runes::Cog::Input
        attr_accessor :prompt, :session

        def validate!
          valid_prompt!
        end

        def coerce(input_return_value)
          self.prompt = input_return_value if input_return_value.is_a?(String)
        end

        def valid_prompt!
          raise InvalidInputError, "'prompt' is required" if Runes.blank?(@prompt)

          @prompt
        end

        def valid_session
          @session
        end
      end

      class Output < Runes::Cog::Output
        include Runes::Cog::Output::WithJson
        include Runes::Cog::Output::WithNumber
        include Runes::Cog::Output::WithText

        attr_reader :response, :session

        def initialize(session, response)
          super()
          @session = session
          @response = response
        end

        def raw_text
          response
        end
      end

      # --- backend seam --------------------------------------------------

      class << self
        attr_writer :backend

        def backend
          @backend ||= default_backend
        end

        def reset_backend!
          @backend = nil
        end

        def default_backend
          if ruby_llm_requested? && ruby_llm_available?
            RubyLLMBackend.new
          else
            RouterBackend.new
          end
        end

        def ruby_llm_requested?
          %w[ruby_llm rubyllm ruby-llm].include?(ENV["RUNES_LLM_ADAPTER"].to_s.strip.downcase)
        end

        def ruby_llm_available?
          require_relative "../llm"
          Runes::LLM::RubyLLMAdapter.available?
        rescue LoadError, StandardError
          false
        end
      end

      # Shared adapter plumbing: build an LLM adapter, send the conversation,
      # map the result hash onto a Reply. The config is resolved *before*
      # `dispatch` runs, so a bad provider/model/temperature can never reach
      # the wire (W5-3).
      class BaseBackend
        def chat(prompt:, session:, config:)
          messages = conversation(session, prompt)
          result = dispatch(messages, config)
          if result.is_a?(Hash) && result[:ok] == false
            error = result[:error].to_s
            # The router reports a length-truncated completion as an error;
            # surface it as the typed error callers can rescue.
            raise MaxTokensExceededError, error if error.include?("finish_reason=length")

            raise Runes::Error, "chat request failed: #{error}"
          end

          response = extract_content(result)
          usage = result.is_a?(Hash) ? result[:usage] : nil
          Reply.new(
            response: response,
            messages: messages + [{ role: "assistant", content: response }],
            model: config.valid_model,
            input_tokens: usage && (usage["prompt_tokens"] || usage[:prompt_tokens]),
            output_tokens: usage && (usage["completion_tokens"] || usage[:completion_tokens])
          )
        end

        private

        # Backends override this to perform the request. `config` has already
        # been validated by `Chat#execute`.
        def dispatch(_messages, _config)
          raise NotImplementedError, "#{self.class} must implement #dispatch"
        end

        def conversation(session, prompt)
          messages = []
          messages.concat(Runes.deep_dup(session.messages)) if session.respond_to?(:messages) && session
          messages << { role: "user", content: prompt }
          messages.map do |message|
            hash = message.respond_to?(:to_h) ? message.to_h : message
            { role: (hash[:role] || hash["role"]).to_s, content: hash[:content] || hash["content"] }
          end
        end

        def extract_content(result)
          return result.to_s unless result.is_a?(Hash)

          result[:content] || result.dig(:raw, "choices", 0, "message", "content") || ""
        end

        def settings
          require_relative "../core/settings"
          Runes::Core::Settings.new
        end
      end

      # `Runes::Core::LLMClient` only routes through its own registry
      # (deepseek/synthetic/cerebras), which does not know Roast's provider
      # names. This subclass adds the chat rune's resolved `provider`,
      # `model`, `temperature`, `api_key` and `base_url` to `#chat`: when the
      # named provider has a key, the request goes to that provider directly;
      # otherwise the base client's key-based routing is used (so a workflow
      # still runs on whatever provider has a key, as documented). Written
      # here rather than in `core/` because the seam is the chat rune (W5-3).
      class RouterClient < Runes::Core::LLMClient
        def chat(messages, system: nil, json: false, variation: nil, tools: nil,
                 provider: nil, model: nil, temperature: nil, api_key: nil, base_url: nil)
          unless messages.is_a?(Array) && messages.all? { |m| m.is_a?(Hash) }
            return err("messages must be an Array of {role, content} hashes")
          end

          route = route_for(provider: provider, model: model, variation: variation,
                            temperature: temperature, api_key: api_key, base_url: base_url)
          return err(last_notice) if route.nil?

          result = call_openai_compatible(route, messages, tools: tools, system: system, json: json)
          result[:provider] = route.provider
          result[:model] = route.model
          result
        end

        private

        def route_for(provider:, model:, temperature:, api_key:, base_url:, variation:)
          if provider && api_key
            Runes::Core::LLMClient::Route.new(
              provider: provider.to_s,
              base_url: base_url,
              model: model,
              variation: variation,
              sampling_params: temperature.nil? ? {} : { temperature: temperature },
              api_key: api_key
            )
          else
            route = resolve_route(provider: nil, model: nil, variation: variation)
            return nil if route.nil?

            route = route.dup
            route.sampling_params = route.sampling_params.merge(temperature: temperature) unless temperature.nil?
            route
          end
        end
      end

      # The default: Runes' own router, picked by whichever provider has a key
      # unless the chat config names a provider that has one.
      class RouterBackend < BaseBackend
        private

        def dispatch(messages, config)
          client = RouterClient.new(settings)
          client.chat(
            messages,
            json: false,
            provider: config.valid_provider!,
            model: config.valid_model,
            temperature: config.valid_temperature,
            api_key: resolved_api_key(config),
            base_url: config.valid_base_url
          )
        end

        # `valid_api_key!` is the validator; a missing key for the named
        # provider falls back to the router's key-based choice rather than
        # aborting (the documented "run on whatever key you have").
        def resolved_api_key(config)
          config.valid_api_key!
        rescue Runes::Cog::Config::InvalidConfigError
          nil
        end
      end

      # Opt-in ruby_llm adapter (RUNES_LLM_ADAPTER=ruby_llm).
      class RubyLLMBackend < BaseBackend
        private

        def dispatch(messages, config)
          # The ruby_llm adapter resolves provider/model from its own
          # settings and its #chat signature has no provider/model/temperature
          # parameters; the chat rune validates them first but cannot thread
          # them through here without changing core/llm (see W5-3 report).
          adapter(config).chat(messages, json: false)
        end

        def adapter(_config)
          require_relative "../llm"
          Runes::LLM.adapter(settings, name: "ruby_llm")
        end
      end

      protected

      def execute(input)
        config = @config
        prompt = input.valid_prompt!
        validate_config!(config)
        reply = self.class.backend.chat(prompt: prompt, session: input.valid_session, config: config)

        display_prompt(prompt) if config.show_prompt?
        display_response(reply.response) if config.show_response?
        display_stats(reply) if config.show_stats?

        Output.new(Session.from_chat(reply), reply.response)
      end

      private

      # Resolve every config value before any backend is invoked. A typo in a
      # provider name must fail here — it used to be detected by
      # `config.valid_model` *after* the HTTP request had already sent the
      # prompt to the router's default provider (W5-3).
      def validate_config!(config)
        config.valid_provider!
        config.valid_base_url
        config.valid_model
        config.valid_temperature
        nil
      end

      def display_prompt(prompt)
        $stdout.puts("USER PROMPT:\n#{prompt}")
      end

      def display_response(response)
        $stdout.puts("LLM RESPONSE:\n#{response}")
      end

      def display_stats(reply)
        lines = ["Model: #{reply.model}"]
        lines << "Input Tokens: #{reply.input_tokens}" if reply.input_tokens
        lines << "Output Tokens: #{reply.output_tokens}" if reply.output_tokens
        $stdout.puts("LLM STATS:\n#{lines.join("\n")}")
      end
    end
  end
end
