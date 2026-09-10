# frozen_string_literal: true

require "pathname"

require_relative "../rune"
require_relative "../command_runner"
require_relative "../workflow/util"

module Runes
  module Plugins
    # The `agent` rune: run a local coding-agent CLI (Pi or Claude Code) with
    # filesystem access, streaming its JSON output and reporting usage stats.
    #
    # Tests inject either a fake provider (`Runes::Plugins::Agent.provider_factory=`)
    # or a fake command runner (`Runes::Plugins::Agent.command_runner=`); no
    # real CLI is spawned by the test suite.
    class Agent < Runes::Rune
      plugin :agent, description: "Run a local coding agent CLI"

      class AgentCogError < Runes::Error; end
      class UnknownProviderError < AgentCogError; end
      class MissingProviderError < AgentCogError; end
      class MissingPromptError < AgentCogError; end

      class << self
        attr_writer :provider_factory, :command_runner

        # A callable `->(config) { provider }`; nil uses the built-in providers.
        def provider_factory
          @provider_factory
        end

        # Defaults to Runes::CommandRunner; inject a double in tests.
        def command_runner
          @command_runner || Runes::CommandRunner
        end

        def provider_for(config)
          return provider_factory.call(config) if provider_factory

          case config.valid_provider!
          when :claude then Providers::Claude.new(config)
          when :pi then Providers::Pi.new(config)
          else raise UnknownProviderError, "Unknown provider: #{config.valid_provider!}"
          end
        end

        def reset_seams!
          @provider_factory = nil
          @command_runner = nil
        end
      end

      # Token usage / cost for one model (or the aggregate).
      class Usage
        attr_accessor :input_tokens, :output_tokens, :cost_usd

        def +(other)
          result = Usage.new
          result.input_tokens = sum_nils(input_tokens, other.input_tokens)&.to_int
          result.output_tokens = sum_nils(output_tokens, other.output_tokens)&.to_int
          result.cost_usd = sum_nils(cost_usd, other.cost_usd)&.to_f
          result
        end

        private

        def sum_nils(left, right)
          return nil if left.nil? && right.nil?

          (left || 0) + (right || 0)
        end
      end

      # Execution statistics across all turns/models.
      class Stats
        NO_VALUE = "---"

        attr_accessor :duration_ms, :num_turns, :usage, :model_usage

        def initialize
          @usage = Usage.new
          @model_usage = {}
        end

        def +(other)
          result = Stats.new
          result.duration_ms = sum_nils(duration_ms, other.duration_ms)&.to_int
          result.num_turns = sum_nils(num_turns, other.num_turns)&.to_int
          result.usage = usage + other.usage
          result.model_usage = model_usage.merge(other.model_usage) { |_model, a, b| a + b }
          result
        end

        def to_s
          lines = []
          lines << "Turns: #{num_turns.nil? ? NO_VALUE : num_turns}"
          lines << "Duration: #{duration_ms.nil? ? NO_VALUE : format_duration(duration_ms)}"
          lines << "Cost (USD): $#{usage.cost_usd.nil? ? NO_VALUE : format('%.6f', usage.cost_usd)}"
          model_usage.each do |model, model_usage_entry|
            input = model_usage_entry.input_tokens.nil? ? NO_VALUE : model_usage_entry.input_tokens
            output = model_usage_entry.output_tokens.nil? ? NO_VALUE : model_usage_entry.output_tokens
            lines << "Tokens (#{model}): #{input} in, #{output} out"
          end
          lines.join("\n")
        end

        private

        def sum_nils(left, right)
          return nil if left.nil? && right.nil?

          (left || 0) + (right || 0)
        end

        def format_duration(milliseconds)
          return "#{milliseconds.round}ms" if milliseconds < 1000

          format("%.2fs", milliseconds / 1000.0)
        end
      end

      class Config < Runes::Cog::Config
        VALID_PROVIDERS = %i[pi claude].freeze
        DEFAULT_PROVIDER_ENV_VAR = "ROAST_DEFAULT_AGENT_PROVIDER"

        def provider(provider)
          @values[:provider] = provider
        end

        def use_default_provider!
          @values[:provider] = nil
        end

        def valid_provider!
          env_default = Runes.presence(ENV[DEFAULT_PROVIDER_ENV_VAR])&.strip&.downcase&.to_sym
          provider = @values[:provider] || env_default || VALID_PROVIDERS.first
          unless VALID_PROVIDERS.include?(provider)
            raise InvalidConfigError,
                  "'#{provider}' is not a valid provider. Available providers include: #{VALID_PROVIDERS.join(', ')}"
          end

          provider
        end

        def command(command)
          @values[:command] = command
        end

        def use_default_command!
          @values[:command] = nil
        end

        def valid_command
          Runes.presence(@values[:command])
        end

        def model(model)
          @values[:model] = model
        end

        def use_default_model!
          @values[:model] = nil
        end

        def valid_model
          Runes.presence(@values[:model])
        end

        def replace_system_prompt(prompt)
          @values[:replace_system_prompt] = prompt
        end

        def no_replace_system_prompt!
          @values[:replace_system_prompt] = ""
        end

        def valid_replace_system_prompt
          Runes.presence(@values[:replace_system_prompt])
        end

        def append_system_prompt(prompt)
          @values[:append_system_prompt] = prompt
        end

        def no_append_system_prompt!
          @values[:append_system_prompt] = ""
        end

        def valid_append_system_prompt
          Runes.presence(@values[:append_system_prompt])
        end

        def apply_permissions!
          @values[:apply_permissions] = true
        end

        def no_apply_permissions!
          @values[:apply_permissions] = false
        end

        def apply_permissions?
          @values.fetch(:apply_permissions, true)
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

        def show_progress!
          @values[:show_progress] = true
        end

        def no_show_progress!
          @values[:show_progress] = false
        end

        def show_progress?
          @values.fetch(:show_progress, true)
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
          show_progress!
          show_response!
          show_stats!
        end

        def no_display!
          no_show_prompt!
          no_show_progress!
          no_show_response!
          no_show_stats!
        end

        def display?
          show_prompt? || show_progress? || show_response? || show_stats?
        end

        def dump_raw_agent_messages_to(filename)
          @values[:dump_raw_agent_messages_to] = filename
        end

        def valid_dump_raw_agent_messages_to_path
          Pathname.new(@values[:dump_raw_agent_messages_to]) if @values[:dump_raw_agent_messages_to]
        end

        # Kill the agent CLI after this many seconds (W5-10). nil = no timeout.
        def timeout(seconds)
          @values[:timeout] = seconds
        end

        def use_default_timeout!
          @values.delete(:timeout)
        end

        def valid_timeout
          raw = @values[:timeout]
          return nil if raw.nil?

          value = Float(raw)
          raise InvalidConfigError, "'timeout' must be positive, got #{raw.inspect}" unless value.positive?

          value
        rescue ArgumentError, TypeError
          raise InvalidConfigError, "'timeout' must be a number of seconds, got #{raw.inspect}"
        end

        def validate!
          valid_timeout
        end

        alias skip_permissions! no_apply_permissions!
        alias no_skip_permissions! apply_permissions!
        alias quiet! no_display!
      end

      class Input < Runes::Cog::Input
        attr_accessor :prompts, :session

        def initialize
          super
          @prompts = []
        end

        def validate!
          raise InvalidInputError, "At least one prompt is required" unless Runes.present?(prompts)
          raise InvalidInputError, "Blank prompts are not allowed" if prompts.any? { |prompt| Runes.blank?(prompt) }
        end

        def coerce(input_return_value)
          case input_return_value
          when String
            self.prompts = [input_return_value]
          when Array
            self.prompts = input_return_value.map(&:to_s)
          end
        end

        def prompt=(prompt)
          @prompts = [prompt]
        end
      end

      class Output < Runes::Cog::Output
        include Runes::Cog::Output::WithJson
        include Runes::Cog::Output::WithNumber
        include Runes::Cog::Output::WithText

        attr_reader :response, :session, :stats

        def initialize(response:, session:, stats:)
          super()
          @response = response
          @session = session
          @stats = stats
        end

        def raw_text
          response
        end
      end

      # Abstract provider: build one per invocation.
      class Provider
        def initialize(config)
          @config = config
        end

        def invoke(_input)
          raise NotImplementedError, "Subclasses must implement #invoke"
        end
      end

      # Shared streaming-invocation behaviour for the CLI providers.
      class CliInvocation
        Result = Struct.new(:response, :success, :session, :stats, keyword_init: true)

        def initialize(config, prompt, session)
          @config = config
          @prompt = prompt
          @session = session
          @response = +""
          @result_session = session
          @success_flag = nil
          @num_turns = 0
          @model_usage = {}
          @total_cost = 0.0
          @duration_ms = nil
          @current_text = +""
        end

        attr_reader :prompt

        def session
          @result_session
        end

        def run!
          display_prompt
          started = monotonic_ms
          result = self.class.runner.execute(
            command_line,
            stdin: @prompt,
            stdout_handler: ->(line) { handle_stdout(line) },
            timeout: @config.valid_timeout,
            # Roast honours the configured working directory; this rune used
            # to accept the setting and silently ignore it (doc5.md W5-9).
            working_directory: @config.valid_working_directory
          )
          @duration_ms = monotonic_ms - started

          if result.status.success?
            @success_flag = true if @success_flag.nil?
            @response = result.out.to_s if @response.empty? && Runes.present?(result.out)
            display_response
          else
            @success_flag = false
            @response += "\n" unless @response.empty? || @response.end_with?("\n")
            @response += result.err.to_s
          end
          self
        end

        def self.runner
          Runes::Plugins::Agent.command_runner
        end

        def success?
          @success_flag != false
        end

        def stats
          stats = Agent::Stats.new
          stats.num_turns = @num_turns
          stats.duration_ms = @duration_ms
          @model_usage.each do |model, accumulator|
            usage = Agent::Usage.new
            usage.input_tokens = accumulator[:input]
            usage.output_tokens = accumulator[:output]
            usage.cost_usd = accumulator[:cost]
            stats.model_usage[model] = usage
            stats.usage.input_tokens = (stats.usage.input_tokens || 0) + usage.input_tokens
            stats.usage.output_tokens = (stats.usage.output_tokens || 0) + usage.output_tokens
          end
          stats.usage.cost_usd = @total_cost
          stats
        end

        def result
          Result.new(response: @response, success: success?, session: @result_session, stats: stats)
        end

        private

        def handle_stdout(line)
          line = line.to_s.strip
          return if line.empty?

          raw_dump(line)
          begin
            data = JSON.parse(line, symbolize_names: true)
          rescue JSON::ParserError
            return
          end
          handle_message(data)
        rescue StandardError
          nil
        end

        def handle_message(_data)
          raise NotImplementedError
        end

        def raw_dump(line)
          path = @config.valid_dump_raw_agent_messages_to_path
          return unless path

          path.dirname.mkpath
          File.write(path.to_s, "#{line}\n", mode: "a")
        end

        def accumulate_usage(model, usage)
          return unless usage.is_a?(Hash)

          key = (model || "unknown").to_s
          accumulator = (@model_usage[key] ||= { input: 0, output: 0, cost: 0.0 })
          accumulator[:input] += (usage[:input_tokens] || usage[:input] || usage[:prompt_tokens] || 0).to_i
          accumulator[:output] += (usage[:output_tokens] || usage[:output] || usage[:completion_tokens] || 0).to_i
          cost = if usage[:cost].is_a?(Hash)
            usage[:cost][:total]
          else
            usage[:cost] || usage[:total_cost_usd]
          end
          accumulator[:cost] += cost.to_f
          @total_cost = @model_usage.values.sum(0.0) { |entry| entry[:cost] }
        end

        def extract_text(content)
          case content
          when String
            content
          when Array
            content.filter_map do |part|
              next unless part.is_a?(Hash)

              part[:text] || part["text"]
            end.join
          else
            ""
          end
        end

        def monotonic_ms
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
        end

        def display_prompt
          $stdout.puts("USER PROMPT:\n#{@prompt}") if @config.show_prompt?
        end

        def display_response
          $stdout.puts("AGENT RESPONSE:\n#{@response}") if @config.show_response?
        end
      end

      class Providers
        # `pi` (default): JSON event stream on stdout, prompt on stdin.
        class Pi < Provider
          class Invocation < CliInvocation
            private

            def command_line
              command = base_command("pi")
              command.push("--mode", "json", "-p")
              model = @config.valid_model
              command.push("--model", model) if model
              replace = @config.valid_replace_system_prompt
              command.push("--system-prompt", replace) if replace
              append = @config.valid_append_system_prompt
              command.push("--append-system-prompt", append) if append
              if Runes.present?(@session)
                command.push("--fork", @session)
              else
                command.push("--no-session")
              end
              command
            end

            def handle_message(data)
              case data[:type]&.to_sym
              when :session
                @result_session = data[:id] if Runes.present?(data[:id])
              when :turn_start
                @num_turns += 1
              when :message_update
                handle_message_update(data)
              when :message_end
                handle_message_end(data)
              when :agent_end
                handle_agent_end(data)
              end
            end

            def handle_message_update(data)
              event = data[:assistantMessageEvent]
              return unless event

              case event[:type]&.to_sym
              when :text_delta
                @current_text << event[:delta].to_s if event[:delta]
              when :text_end
                @response = event[:content] if Runes.present?(event[:content])
                @response = @current_text.dup if !Runes.present?(event[:content]) && Runes.present?(@current_text)
                $stdout.puts(@current_text) if Runes.present?(@current_text) && @config.show_progress?
                @current_text = +""
              end
            end

            def handle_message_end(data)
              message = data[:message]
              return unless message

              return unless message[:role]&.to_sym == :assistant

              accumulate_usage(message[:model], message[:usage]) if message[:usage] && message[:model]
              text = extract_text(message[:content])
              @response = text if Runes.present?(text)
            end

            def handle_agent_end(data)
              messages = data[:messages]
              return unless messages.is_a?(Array)

              last_assistant = messages.reverse.find { |message| message[:role].to_s == "assistant" }
              return unless last_assistant

              text = extract_text(last_assistant[:content])
              @response = text if Runes.present?(text)
            end

            def base_command(default)
              case @config.valid_command
              when Array then @config.valid_command.dup
              when String then @config.valid_command.split
              else [default]
              end
            end
          end

          def invoke(input)
            run_prompts(input) { |prompt, session| Invocation.new(@config, prompt, session) }
          end

          private

          def run_prompts(input)
            invocations = []
            input.prompts.each do |prompt|
              previous_session = invocations.last&.session
              invocation = yield(prompt, previous_session || input.session)
              invocation.run!
              invocations << invocation
              break unless invocation.success?
            end
            finalize(invocations)
          end

          def finalize(invocations)
            final = invocations.last.result
            if invocations.size > 1
              final.stats = invocations.map { |invocation| invocation.result.stats }.compact.reduce(:+)
            end
            Agent::Output.new(response: final.response, session: final.session, stats: final.stats)
          end
        end

        # `claude`: stream-json on stdout, prompt on stdin.
        class Claude < Provider
          class Invocation < CliInvocation
            def initialize(config, prompt, session, fork_session: true)
              super(config, prompt, session)
              @fork_session = fork_session
            end

            private

            def command_line
              command = base_command("claude")
              command.push("-p", "--verbose", "--output-format", "stream-json")
              model = @config.valid_model
              command.push("--model", model.delete_prefix("anthropic/")) if model
              replace = @config.valid_replace_system_prompt
              command.push("--system-prompt", replace) if replace
              append = @config.valid_append_system_prompt
              command.push("--append-system-prompt", append) if append
              if Runes.present?(@session)
                command.push("--fork-session") if @fork_session
                command.push("--resume", @session)
              end
              command << "--dangerously-skip-permissions" unless @config.apply_permissions?
              command
            end

            def handle_message(data)
              @result_session = data[:session_id] if Runes.present?(data[:session_id])

              case data[:type].to_s
              when "assistant"
                message = data[:message] || {}
                text = extract_text(message[:content])
                @response = text if Runes.present?(text)
                accumulate_usage(message[:model], message[:usage]) if message[:usage]
              when "result"
                handle_result(data)
              end
            end

            def handle_result(data)
              @response = data[:result].to_s if data.key?(:result)
              @success_flag = data[:subtype].to_s == "success" && !data[:is_error]
              @total_cost = data[:total_cost_usd].to_f if data[:total_cost_usd]
              @num_turns = data[:num_turns].to_i if data[:num_turns]
              @duration_ms = data[:duration_ms].to_i if data[:duration_ms]
              accumulate_usage(@config.valid_model, data[:usage]) if data[:usage]
            end

            def base_command(default)
              case @config.valid_command
              when Array then @config.valid_command.dup
              when String then @config.valid_command.split
              else [default]
              end
            end
          end

          def invoke(input)
            invocations = []
            input.prompts.each do |prompt|
              previous_session = invocations.last&.session
              invocation = Invocation.new(
                @config,
                prompt,
                previous_session || input.session,
                fork_session: previous_session.nil?
              )
              invocation.run!
              invocations << invocation
              break unless invocation.success?
            end

            final = invocations.last.result
            if invocations.size > 1
              final.stats = invocations.map { |invocation| invocation.result.stats }.compact.reduce(:+)
            end
            Agent::Output.new(response: final.response, session: final.session, stats: final.stats)
          end
        end
      end

      protected

      def execute(input)
        output = self.class.provider_for(@config).invoke(input)
        $stdout.puts("AGENT STATS:\n#{output.stats}\nSession ID: #{output.session}") if @config.show_stats?
        output
      end
    end
  end
end
