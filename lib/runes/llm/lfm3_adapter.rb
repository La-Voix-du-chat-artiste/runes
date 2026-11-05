# frozen_string_literal: true

require_relative 'command_model'
require_relative 'openai_compat_model'
require_relative 'adapter_support'
require_relative '../swarm/model_family'

module Runes
  module LLM
    # The LFM3-1.7B text seam.
    #
    # Two modes:
    #   :command -> explicit argv, prompt on stdin, answer on stdout, through
    #               bench/swarm/lfm3_cli.py;
    #   :server  -> a warm OpenAI-compatible server, through
    #               OpenAICompatModel.
    #
    # The adapter never owns a plan and never creates an identity. It is a
    # transport plus a sampler choice; RoleProfile supplies the prompt and
    # the conductor supplies the manifest.
    class Lfm3Adapter
      DEFAULT_MODEL = 'LiquidAI/LFM3-1.7B'
      DEFAULT_MAX_TOKENS = 320

      # Answer/critic/repair: low temperature, small nucleus.
      DEFAULT_SAMPLER = {
        temperature: 0.1,
        top_k: 50,
        repetition_penalty: 1.1
      }.freeze

      # Ideation: a little more diversity, but still bounded.
      IDEATION_SAMPLER = {
        temperature: 0.35,
        top_p: 0.95,
        top_k: 50
      }.freeze

      # Math only, explicitly labelled in the receipt.
      MATH_SAMPLER = {
        temperature: 1.0,
        top_p: 0.95,
        top_k: 20
      }.freeze

      MODES = %i[command server].freeze
      SAMPLER_FLAGS = %w[
        temperature top_p top_k repetition_penalty presence_penalty
      ].freeze

      attr_reader :mode, :sampler, :model_name, :backend, :max_tokens,
                  :cli_path, :python, :base_url

      def initialize(mode: :command, command: nil, base_url: nil, model: nil,
                     python: nil, cli: nil, api_key: nil, timeout_s: 300,
                     max_tokens: DEFAULT_MAX_TOKENS, sampler: nil,
                     runner: nil, transport: nil)
        @mode = mode.to_s.to_sym
        unless MODES.include?(@mode)
          raise ArgumentError, "lfm3 adapter: mode must be :command or :server, got #{mode.inspect}"
        end

        @model_name = model.to_s.empty? ? DEFAULT_MODEL : model.to_s
        @sampler_given = !sampler.nil?
        @sampler = sampler || DEFAULT_SAMPLER
        @max_tokens = integer!(max_tokens, :max_tokens)
        @command = command
        @command_given = !command.nil?
        @python = python.to_s.empty? ? 'python3' : python.to_s
        @cli_path = cli.to_s.empty? ? self.class.default_cli : cli.to_s
        @base_url = base_url.to_s
        @api_key = api_key
        @timeout_s = timeout_s
        @runner = runner
        @transport = transport
        @backend = build_backend(@sampler, prompt: nil)
      end

      def self.from_env(env = ENV, **overrides)
        if env.equal?(ENV) && !overrides.empty? &&
           overrides.keys.all? { |key| key.to_s.start_with?('LFM3_') }
          env = overrides
          overrides = {}
        end
        mode = (env['LFM3_MODE'] || 'command').to_sym
        max_tokens = env['LFM3_MAX_TOKENS'].to_s.empty? ? DEFAULT_MAX_TOKENS : env['LFM3_MAX_TOKENS'].to_i
        new(
          mode: mode,
          model: env['LFM3_MODEL'] || DEFAULT_MODEL,
          python: env['LFM3_PYTHON'],
          cli: env['LFM3_CLI'] || default_cli,
          base_url: env['LFM3_BASE_URL'],
          api_key: env['LFM3_API_KEY'],
          max_tokens: max_tokens,
          **overrides
        )
      end

      def self.default_cli
        File.expand_path('../../../bench/swarm/lfm3_cli.py', __dir__)
      end

      # Explicit sampler selection for a role or a labelled math case. The
      # caller decides; the adapter does not guess from prose.
      def self.sampler_for(role = nil, math: false)
        return MATH_SAMPLER if math

        case role.to_s.to_sym
        when :ideator, :ideator_direct, :ideator_alternative then IDEATION_SAMPLER
        else DEFAULT_SAMPLER
        end
      end

      def call(prompt, role: nil, max_tokens: nil, sampler: nil, math: false)
        chosen = choose_sampler(sampler, role: role, math: math)
        backend = build_backend(chosen, prompt: prompt)
        result = backend.call(
          prompt,
          role: role,
          max_tokens: max_tokens.nil? ? @max_tokens : integer!(max_tokens, :max_tokens)
        )
        AdapterSupport.envelope_result(
          result,
          family: result_family,
          modalities: modalities
        )
      end

      def available?
        return @backend.available? if @mode == :server

        return false unless command_available?
        return true if @command_given
        return false unless File.file?(@cli_path)
        return false if AdapterSupport.path_like?(@model_name) &&
                        !File.exist?(AdapterSupport.expanded_path(@model_name))

        true
      end

      def availability_error
        return @backend.availability_error if @mode == :server
        return "LFM3 model command not executable: #{Array(@command).first.inspect}" unless command_available?
        return "LFM3 CLI not found: #{@cli_path}" unless @command_given || File.file?(@cli_path)
        if !@command_given && AdapterSupport.path_like?(@model_name) &&
           !File.exist?(AdapterSupport.expanded_path(@model_name))
          return "LFM3 model path not found: #{@model_name}"
        end

        nil
      end

      def family
        @family ||= Runes::Swarm::ModelFamily.fetch(@model_name)
      rescue Runes::Swarm::ModelFamily::Invalid
        nil
      end

      def modalities
        found = family
        found.nil? ? ['text'] : found.modalities.map(&:to_s)
      end

      def result_family
        found = family
        found.nil? ? @model_name : found.model
      end

      def self.clean_output(text, prompt: nil)
        AdapterSupport.clean_output(text, prompt: prompt)
      end

      private

      def choose_sampler(value, role:, math:)
        return self.class.sampler_for(role, math: true) if math
        return value if value.is_a?(Hash)
        case value.to_s.to_sym
        when :math then return MATH_SAMPLER
        when :ideation, :ideator then return IDEATION_SAMPLER
        when :default, :text then return DEFAULT_SAMPLER
        end
        return self.class.sampler_for(value, math: false) if value.is_a?(Symbol) || value.is_a?(String)

        if !@sampler_given && %i[ideator ideator_direct ideator_alternative].include?(role.to_s.to_sym)
          return IDEATION_SAMPLER
        end

        @sampler
      end

      def build_backend(chosen_sampler, prompt:)
        if @mode == :server
          return OpenAICompatModel.new(
            base_url: @base_url,
            model: @model_name,
            api_key: @api_key,
            timeout_s: @timeout_s,
            sampler: chosen_sampler,
            transport: @transport
          )
        end

        argv = @command_given ? @command : build_command(chosen_sampler)
        CommandModel.new(
          command: argv,
          timeout_s: @timeout_s,
          cleaner: ->(text) { AdapterSupport.clean_output(text, prompt: prompt) },
          model_name: @model_name,
          runner: @runner
        )
      end

      def build_command(chosen_sampler)
        argv = [
          @python, @cli_path,
          '--model', @model_name,
          '--max-tokens', @max_tokens.to_s
        ]
        SAMPLER_FLAGS.each do |key|
          next unless chosen_sampler.key?(key.to_sym)

          value = chosen_sampler[key.to_sym]
          next if value.nil?

          argv << "--#{key.tr('_', '-')}" << value.to_s
        end
        argv << '--enable-thinking' if chosen_sampler[:enable_thinking]
        argv
      end

      def command_available?
        return @backend.available? if @command_given

        true
      end

      def integer!(value, field)
        unless value.is_a?(Integer) && !value.negative?
          raise ArgumentError, "lfm3 adapter: #{field} must be a non-negative Integer, got #{value.inspect}"
        end

        value
      end
    end
  end
end
