# frozen_string_literal: true

require_relative 'command_model'
require_relative 'openai_compat_model'
require_relative 'adapter_support'
require_relative '../swarm/model_family'
require_relative '../swarm/decision'
require_relative '../swarm/envelope'

module Runes
  module LLM
    # The d1 typed-decision seam.
    #
    # d1 is not a chat model: it does not sample and does not generate prose.
    # `system_one` sends one state, a list of typed questions and optional
    # media, and returns a validated `verdict.v1` artifact. It is the only
    # adapter allowed to emit a verdict.
    class D1Adapter
      DEFAULT_MODEL = 'LiquidAI/d1-2B'
      OMNI_MODEL = 'LiquidAI/d1-Omni-2B'
      MODES = %i[command server].freeze

      AUDIO = %w[.wav .mp3 .m4a .flac .ogg .aac .opus .aiff .aif].freeze
      IMAGE = %w[.png .jpg .jpeg .gif .webp .bmp .tiff .tif].freeze
      VIDEO = %w[.mp4 .mov .mkv .webm .avi .m4v].freeze

      attr_reader :mode, :model_name, :backend, :cli_path, :python, :base_url

      def initialize(mode: :command, command: nil, base_url: nil, model: nil,
                     python: nil, cli: nil, api_key: nil, timeout_s: 300,
                     runner: nil, transport: nil)
        @mode = mode.to_s.to_sym
        unless MODES.include?(@mode)
          raise ArgumentError, "d1 adapter: mode must be :command or :server, got #{mode.inspect}"
        end

        @model_name = model.to_s.empty? ? DEFAULT_MODEL : model.to_s
        @command = command
        @command_given = !command.nil?
        @python = python.to_s.empty? ? 'python3' : python.to_s
        @cli_path = cli.to_s.empty? ? self.class.default_cli : cli.to_s
        @base_url = base_url.to_s
        @api_key = api_key
        @timeout_s = timeout_s
        @runner = runner
        @transport = transport
        @backend = build_backend
      end

      def self.from_env(env = ENV, omni: false, family: nil, **overrides)
        if env.equal?(ENV) && !overrides.empty? &&
           overrides.keys.all? { |key| key.to_s.start_with?('LFM3_') }
          env = overrides
          overrides = {}
        end
        omni = true if family.to_s == 'omni'
        mode = (env['LFM3_MODE'] || 'command').to_sym
        model = if omni
                  env['LFM3_D1_OMNI_MODEL'] || OMNI_MODEL
                else
                  env['LFM3_D1_MODEL'] || DEFAULT_MODEL
                end
        new(
          mode: mode,
          model: model,
          python: env['LFM3_PYTHON'],
          cli: env['LFM3_CLI_D1'] || env['LFM3_CLI'] || default_cli,
          base_url: env['LFM3_BASE_URL'],
          api_key: env['LFM3_API_KEY'],
          **overrides
        )
      end

      def self.default_cli
        File.expand_path('../../../bench/swarm/d1_cli.py', __dir__)
      end

      # Common adapter contract: call(state, questions, ...). The name
      # `system_one` is kept because d1 accepts exactly one state per call.
      def call(state, questions = [], **kwargs)
        system_one(state, questions, **kwargs)
      end

      def system_one(state, questions, media: nil, role: nil, manifest: nil)
        typed = normalize_questions(questions)
        state_text = state_text(state)
        media_info = media_info(media)

        if media_info && !media_info[:error].nil?
          return decline(
            reason: media_error_reason(media_info),
            message: media_info[:error],
            family: result_family,
            modalities: modalities,
            manifest: manifest
          )
        end

        if media_info && !family_accepts?(media_info[:modality])
          return decline(
            reason: :out_of_modality,
            message: "#{@model_name} cannot consume #{media_info[:modality]} media",
            family: result_family,
            modalities: modalities,
            manifest: manifest
          )
        end

        raw = if @mode == :server
                server_call(state_text, typed, media_info, role: role)
              else
                command_call(state_text, typed, media_info, role: role)
              end
        return raw if raw.is_a?(Hash) && raw[:ok] == false && raw[:artifact].nil? && raw[:status] != :ok

        artifact = AdapterSupport.read_json_object(raw[:content])
        return parse_failure(raw, 'd1 returned a non-JSON artifact', manifest: manifest) if artifact.nil?

        artifact = stringify(artifact)
        answers = normalize_answers(artifact)
        unless probabilities_valid?(artifact, answers)
          return parse_failure(raw, 'd1 returned a probability outside [0, 1]', manifest: manifest)
        end

        decision = build_decision(artifact, raw[:content])
        if decision.is_a?(String)
          return parse_failure(raw, decision, manifest: manifest)
        end

        envelope = manifest.nil? ? nil : Runes::Swarm::Envelope.stamp(
          manifest: manifest,
          decision: decision,
          body: decision.accept? ? decision_body(artifact, raw[:content]) : ''
        )

        AdapterSupport.envelope_result(
          raw,
          family: result_family,
          modalities: modalities,
          extra: {
            artifact: artifact,
            answers: answers,
            decision: decision,
            envelope: envelope,
            role: role
          }
        )
      end

      def available?
        return @backend.available? if @mode == :server

        return false unless @command_given || File.file?(@cli_path)
        if !@command_given && AdapterSupport.path_like?(@model_name) &&
           !File.exist?(AdapterSupport.expanded_path(@model_name))
          return false
        end

        @command_given ? @backend.available? : true
      end

      def availability_error
        return @backend.availability_error if @mode == :server
        return "d1 CLI not found: #{@cli_path}" unless @command_given || File.file?(@cli_path)
        if !@command_given && AdapterSupport.path_like?(@model_name) &&
           !File.exist?(AdapterSupport.expanded_path(@model_name))
          return "d1 model path not found: #{@model_name}"
        end

        @command_given ? @backend.availability_error : nil
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

      private

      def build_backend
        if @mode == :server
          return OpenAICompatModel.new(
            base_url: @base_url,
            model: @model_name,
            api_key: @api_key,
            timeout_s: @timeout_s,
            sampler: {},
            transport: @transport
          )
        end

        argv = @command_given ? @command : build_command
        CommandModel.new(
          command: argv,
          timeout_s: @timeout_s,
          cleaner: ->(text) { AdapterSupport.clean_output(text) },
          model_name: @model_name,
          runner: @runner
        )
      end

      def build_command
        [
          @python, @cli_path,
          '--model', @model_name,
          '--state', '__STATE__',
          '--questions', '__QUESTIONS__'
        ]
      end

      # The state and questions are per-call, so command mode cannot use the
      # backend's fixed argv. Rebuild the array with the call's values.
      def command_call(state_text, questions, media_info, role:)
        argv = [
          @python, @cli_path,
          '--model', @model_name,
          '--state', state_text,
          '--questions', Runes::Json.generate(questions)
        ]
        argv += ['--media', media_info[:path]] if media_info
        model = CommandModel.new(
          command: argv,
          timeout_s: @timeout_s,
          cleaner: ->(text) { AdapterSupport.clean_output(text) },
          model_name: @model_name,
          runner: @runner
        )
        result = model.call('', role: role)
        AdapterSupport.envelope_result(result, family: result_family, modalities: modalities)
      end

      def server_call(state_text, questions, media_info, role:)
        media_line = media_info ? "\nMedia: #{media_info[:path]} (#{media_info[:modality]})\n" : ''
        prompt = <<~PROMPT
          State:
          #{state_text}

          Typed questions (return one answer per id):
          #{Runes::Json.generate(questions)}
          #{media_line}
          Return only a JSON object. Include `answers` as a list of
          `{ "id": ..., "probability": <0..1>, "value": ... }` objects, and
          optional `status`, `reason_code` and `calibration` fields.
        PROMPT
        result = @backend.call(prompt, role: role)
        AdapterSupport.envelope_result(result, family: result_family, modalities: modalities)
      end

      def normalize_questions(questions)
        if questions.is_a?(String)
          stripped = questions.strip
          if stripped.start_with?('{') || stripped.start_with?('[')
            begin
              questions = Runes::Json.parse(stripped)
            rescue Runes::Json::ParseError
              # Keep it as a single free-form question below.
            end
          end
        end
        entries =
          if questions.is_a?(Hash)
            questions.map { |id, value| { 'id' => id.to_s, 'question' => value.to_s } }
          else
            Array(questions)
          end
        entries.each_with_index.map do |entry, index|
          if entry.is_a?(Hash)
            hash = AdapterSupport.stringify_keys(entry)
            id = hash['id'] || hash['name'] || "q#{index + 1}"
            text = hash['question'] || hash['prompt'] || hash['text']
            raise ArgumentError, "d1 adapter: question #{id.inspect} has no prompt" if text.to_s.strip.empty?

            out = { 'id' => id.to_s, 'question' => text.to_s }
            out['type'] = hash['type'].to_s unless hash['type'].nil?
            out['options'] = hash['options'] unless hash['options'].nil?
            out['choices'] = hash['choices'] unless hash['choices'].nil?
            out
          else
            raise ArgumentError, "d1 adapter: question #{index + 1} is empty" if entry.to_s.strip.empty?

            { 'id' => "q#{index + 1}", 'question' => entry.to_s }
          end
        end
      end

      def state_text(state)
        case state
        when Hash, Array
          Runes::Json.generate(state)
        else
          state.to_s
        end
      end

      def media_info(media)
        return nil if media.nil?

        if media.is_a?(Array)
          raise ArgumentError, 'd1 adapter: one media input per call' if media.size > 1

          media = media.first
        end
        return nil if media.nil?

        if media.is_a?(Hash)
          hash = AdapterSupport.stringify_keys(media)
          path = hash['path'] || hash['file'] || hash['input']
          modality = hash['modality']&.to_s&.to_sym
        else
          path = media.to_s
          modality = nil
        end

        return { error: 'd1 adapter: media entry has no path', modality: nil } if path.to_s.empty?

        unless File.file?(AdapterSupport.expanded_path(path))
          return { error: "d1 adapter: unreadable media #{path}", modality: modality || infer_modality(path) }
        end

        { path: AdapterSupport.expanded_path(path), modality: modality || infer_modality(path) }
      end

      def infer_modality(path)
        extension = File.extname(path.to_s).downcase
        return :audio if AUDIO.include?(extension)
        return :image if IMAGE.include?(extension)
        return :video if VIDEO.include?(extension)

        :text
      end

      def family_accepts?(modality)
        found = family
        found.nil? || found.accepts_modality?(modality)
      end

      def media_error_reason(info)
        case info[:modality]
        when :audio then :needs_audio
        when :image, :video then :needs_vision
        else :needs_perception
        end
      end

      def normalize_answers(artifact)
        raw =
          if artifact.is_a?(Hash) && artifact['answers'].is_a?(Array)
            artifact['answers']
          elsif artifact.is_a?(Hash) && artifact['answer'].is_a?(Hash)
            [artifact['answer']]
          elsif artifact.is_a?(Hash) && artifact['id'] && (artifact.key?('probability') || artifact.key?('value'))
            [artifact]
          elsif artifact.is_a?(Hash)
            artifact.reject { |key, _| %w[status reason_code next_hop message calibration decision body].include?(key) }
                    .map { |id, value| { 'id' => id.to_s, 'value' => value } }
          else
            []
          end
        raw.map { |entry| AdapterSupport.stringify_keys(entry) }
      end

      def probabilities_valid?(artifact, answers)
        candidates = []
        answers.each do |answer|
          %w[probability prob p confidence score].each do |key|
            candidates << answer[key] if answer.key?(key)
          end
        end
        if artifact.is_a?(Hash) && artifact['calibration'].is_a?(Hash)
          artifact['calibration'].each_value { |value| candidates << value }
        end
        candidates.all? do |value|
          next true if value.nil?
          next true unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)

          number = value.to_f
          number >= 0.0 && number <= 1.0
        end
      end

      def build_decision(artifact, raw)
        status = artifact['status']
        decision = artifact['decision']
        if decision.is_a?(Hash)
          decision = AdapterSupport.stringify_keys(decision)
          status ||= decision['status']
          reason = decision['reason_code'] || decision['reason']
          next_hop = decision['next_hop'] || decision['next']
          message = decision['message']
        else
          reason = artifact['reason_code'] || artifact['reason']
          next_hop = artifact['next_hop'] || artifact['next']
          message = artifact['message']
        end

        if artifact['decline'] == true
          status = 'decline'
          reason ||= 'low_support'
        end
        status = 'accept' if status.nil?

        normalized = status.to_s.downcase
        reason = 'ok' if normalized == 'accept' && reason.to_s.empty?
        reason = 'low_confidence' if normalized == 'decline' && reason.to_s.empty?
        reason = 'needs_frontier' if normalized == 'escalate' && reason.to_s.empty?
        body = normalized == 'accept' ? decision_body(artifact, raw) : ''

        Runes::Swarm::Decision.new(
          status: normalized,
          reason_code: reason,
          next_hop: next_hop,
          message: message,
          body: body
        )
      rescue Runes::Swarm::Decision::Invalid => e
        e.message
      end

      def decision_body(artifact, raw)
        body = artifact['body'] if artifact.is_a?(Hash)
        body = raw if body.nil? || body.to_s.strip.empty?
        body.to_s
      end

      def parse_failure(raw, message, manifest:)
        envelope = nil
        if manifest
          decision = Runes::Swarm::Decision.new(
            status: :decline, reason_code: :contract_invalid, message: message
          )
          envelope = Runes::Swarm::Envelope.stamp(manifest: manifest, decision: decision, body: '')
        end
        AdapterSupport.envelope_result(
          raw,
          family: result_family,
          modalities: modalities,
          extra: { ok: false, status: :error, error: message, artifact: nil, answers: [], envelope: envelope }
        )
      end

      def decline(reason:, message:, family:, modalities:, manifest:)
        decision = Runes::Swarm::Decision.new(
          status: :decline, reason_code: reason, message: message
        )
        envelope = manifest.nil? ? nil : Runes::Swarm::Envelope.stamp(
          manifest: manifest, decision: decision, body: ''
        )
        AdapterSupport.failure(
          :declined,
          message,
          family: family,
          modalities: modalities,
          extra: { decision: decision, envelope: envelope, artifact: nil }
        )
      end

      def stringify(value)
        return value.map { |entry| stringify(entry) } if value.is_a?(Array)
        if value.is_a?(Hash)
          return AdapterSupport.stringify_keys(value).each_with_object({}) do |(key, entry), out|
            out[key] = stringify(entry)
          end
        end

        value
      end

      def integer!(value, field)
        unless value.is_a?(Integer) && !value.negative?
          raise ArgumentError, "d1 adapter: #{field} must be a non-negative Integer, got #{value.inspect}"
        end

        value
      end
    end
  end
end
