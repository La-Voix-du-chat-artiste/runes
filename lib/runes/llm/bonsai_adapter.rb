# frozen_string_literal: true

require_relative 'command_model'
require_relative 'openai_compat_model'

module Runes
  module LLM
    # Bonsai 2B local adapter.
    #
    # Two modes:
    #   :command -> stdin→stdout through bench/cumulative/bonsai_cli.py
    #   :server  -> the stock mlx_vlm OpenAI-compatible server
    #
    # The model card's non-thinking sampler is the default:
    # temperature 0.7, top_p 0.80, top_k 20, presence_penalty 1.5.
    class BonsaiAdapter
      DEFAULT_SAMPLER = {
        temperature: 0.7,
        top_p: 0.8,
        top_k: 20,
        presence_penalty: 1.5
      }.freeze

      DEFAULT_MAX_TOKENS = 320

      attr_reader :mode, :sampler, :model_name, :backend

      def initialize(mode: :command, command: nil, base_url: nil, model: nil,
                     python: nil, cli: nil, timeout_s: 300,
                     max_tokens: DEFAULT_MAX_TOKENS, sampler: DEFAULT_SAMPLER,
                     runner: nil, transport: nil)
        @mode = mode.to_sym
        @sampler = sampler || DEFAULT_SAMPLER
        @model_name = model.to_s
        @max_tokens = max_tokens
        @command_given = !command.nil?
        @cli_path = cli.to_s.empty? ? self.class.default_cli : cli.to_s
        @backend = build_backend(command: command, base_url: base_url, model: model,
                                 python: python, cli: cli, timeout_s: timeout_s,
                                 runner: runner, transport: transport)
      end

      def self.from_env(env = ENV)
        mode = (env['BONSAI_MODE'] || 'command').to_sym
        model = env['BONSAI_MODEL']
        python = env['BONSAI_PYTHON']
        cli = env['BONSAI_CLI'] || default_cli
        base_url = env['BONSAI_BASE_URL']
        new(mode: mode, model: model, python: python, cli: cli, base_url: base_url)
      end

      def self.default_cli
        File.expand_path('../../../bench/cumulative/bonsai_cli.py', __dir__)
      end

      def call(prompt, role: nil, max_tokens: nil)
        @backend.call(prompt, role: role, max_tokens: max_tokens || @max_tokens)
      end

      def available?
        return @backend.available? unless @mode == :command
        return false unless @backend.available?
        return true if @command_given
        return false unless File.file?(@cli_path)
        return false if path_like?(@model_name) && !File.exist?(expanded(@model_name))

        true
      end

      def availability_error
        return @backend.availability_error unless @mode == :command
        return "Bonsai CLI not found: #{@cli_path}" unless @command_given || File.file?(@cli_path)
        if !@command_given && path_like?(@model_name) && !File.exist?(expanded(@model_name))
          return "Bonsai model path not found: #{@model_name}"
        end

        @backend.availability_error
      end

      def self.clean_output(text)
        clean = text.to_s.gsub(/\e\[[0-9;]*m/, '')
        blocks = clean.split(/^=+\s*$/).map(&:strip).reject(&:empty?)
        answer = blocks.find { |block| !block.match?(/\A(Prompt|Generation|Peak memory):/) }
        (answer || clean).strip
      end

      private

      def path_like?(text)
        text.include?(File::SEPARATOR) || text.start_with?('~')
      end

      def expanded(text)
        text.start_with?('~') ? File.expand_path(text) : text
      end

      def build_backend(command:, base_url:, model:, python:, cli:, timeout_s:, runner:, transport:)
        if @mode == :server
          return OpenAICompatModel.new(
            base_url: base_url.to_s,
            model: model.to_s,
            timeout_s: timeout_s,
            sampler: @sampler,
            transport: transport
          )
        end

        argv = command || build_command(model: model, python: python, cli: cli)
        CommandModel.new(
          command: argv,
          timeout_s: timeout_s,
          cleaner: ->(text) { self.class.clean_output(text) },
          model_name: model.to_s.empty? ? 'bonsai-2b' : model.to_s,
          runner: runner
        )
      end

      def build_command(model:, python:, cli:)
        executable = python.to_s.empty? ? 'python3' : python
        script = cli.to_s.empty? ? self.class.default_cli : cli
        [
          executable, script,
          '--model', model.to_s,
          '--max-tokens', @max_tokens.to_s,
          '--temperature', @sampler[:temperature].to_s,
          '--top-p', @sampler[:top_p].to_s,
          '--top-k', @sampler[:top_k].to_s,
          '--presence-penalty', @sampler[:presence_penalty].to_s
        ]
      end
    end
  end
end
