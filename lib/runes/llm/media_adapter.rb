# frozen_string_literal: true

require_relative 'command_model'
require_relative 'openai_compat_model'
require_relative 'adapter_support'
require_relative '../swarm/model_family'
require_relative '../swarm/decision'
require_relative '../swarm/envelope'

module Runes
  module LLM
    # Shared seam for the three perception adapters.
    #
    # One call is one media artifact in, one `perception.v1` out. The adapter
    # owns the provenance fields (`source_sha256`, anchors, chunk metadata);
    # the model only supplies the description/transcript. A missing or
    # unreadable file is a typed decline, never a silent empty perception.
    class MediaAdapter
      FAMILIES = {
        vision: {
          role: :vision,
          model: 'LiquidAI/LFM3-VL-2B',
          env: 'LFM3_VL_MODEL',
          modalities: %i[image video],
          default_anchor: 'image:1'
        },
        audio: {
          role: :audio,
          model: 'LiquidAI/LFM3-Audio-2B',
          env: 'LFM3_AUDIO_MODEL',
          modalities: %i[audio],
          default_anchor: 'time:0'
        },
        omni: {
          role: :omni,
          model: 'LiquidAI/LFM3-Omni-2B',
          env: 'LFM3_OMNI_MODEL',
          modalities: %i[image video audio],
          default_anchor: 'frame:0'
        }
      }.freeze

      MODES = %i[command server].freeze

      AUDIO = %w[.wav .mp3 .m4a .flac .ogg .aac .opus .aiff .aif].freeze
      IMAGE = %w[.png .jpg .jpeg .gif .webp .bmp .tiff .tif .pdf].freeze
      VIDEO = %w[.mp4 .mov .mkv .webm .avi .m4v].freeze

      ANCHOR = /(?:page|box|time|frame|image|paragraph|line|offset)\s*[:=]\s*[^\s;]+/i
      TIME_ANCHOR = /\[\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?\]/

      attr_reader :family_name, :model_name, :mode, :max_tokens, :backend,
                  :cli_path, :python, :base_url

      def initialize(family: nil, model: nil, mode: :command, command: nil,
                     base_url: nil, python: nil, cli: nil, api_key: nil,
                     timeout_s: 300, max_tokens: 512, runner: nil, transport: nil,
                     manifest: nil)
        @family_name = (family || self.class.family_name).to_s.to_sym
        definition = FAMILIES[@family_name]
        raise ArgumentError, "media adapter: unknown family #{family.inspect}" if definition.nil?

        @mode = mode.to_s.to_sym
        unless MODES.include?(@mode)
          raise ArgumentError, "media adapter: mode must be :command or :server, got #{mode.inspect}"
        end

        @model_name = model.to_s.empty? ? definition[:model] : model.to_s
        # Accept the canonical checkpoint and its packaging variants
        # (e.g. LiquidAI/LFM3-VL-2B-MLX-4bit for LiquidAI/LFM3-VL-2B).
        unless @model_name == definition[:model] ||
               @model_name.start_with?("#{definition[:model]}-")
          raise ArgumentError,
                "#{@family_name} adapter requires #{definition[:model]} (or a -variant), got #{@model_name.inspect}"
        end

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
        @manifest = manifest
        @backend = build_backend
      end

      def self.family_name
        const_defined?(:FAMILY, false) ? const_get(:FAMILY) : nil
      end

      def self.default_model(family = family_name)
        FAMILIES.fetch(family.to_s.to_sym)[:model]
      end

      def self.from_env(env = ENV, family: nil, **overrides)
        if env.equal?(ENV) && !overrides.empty? &&
           overrides.keys.all? { |key| key.to_s.start_with?('LFM3_') }
          env = overrides
          overrides = {}
        end
        family ||= family_name
        definition = FAMILIES.fetch(family.to_s.to_sym)
        new(
          family: family,
          model: env[definition[:env]] || definition[:model],
          mode: (env['LFM3_MODE'] || 'command').to_sym,
          python: env['LFM3_PYTHON'],
          cli: env['LFM3_CLI'] || default_cli,
          base_url: env['LFM3_BASE_URL'],
          api_key: env['LFM3_API_KEY'],
          max_tokens: env['LFM3_MAX_TOKENS'].to_s.empty? ? 512 : env['LFM3_MAX_TOKENS'].to_i,
          **overrides
        )
      end

      def self.default_cli
        File.expand_path('../../../bench/swarm/lfm3_media_cli.py', __dir__)
      end

      def call(input = nil, media: nil, role: nil, max_tokens: nil,
               modality: nil, chunk: nil, manifest: nil, offset: nil, length: nil)
        chunk ||= { offset: offset, length: length } unless offset.nil? && length.nil?
        source = input.nil? ? media : input
        manifest ||= @manifest
        info = source_info(source, modality: modality, chunk: chunk)
        if info.is_a?(Hash) && info[:decline]
          return decline(reason: info[:reason], message: info[:message], manifest: manifest)
        end

        if info[:modality].nil? || !definition[:modalities].include?(info[:modality])
          return decline(
            reason: :out_of_modality,
            message: "#{@model_name} cannot consume #{info[:modality].inspect} media",
            manifest: manifest
          )
        end

        content = if @mode == :server
                    server_call(info, role: role)
                  else
                    command_call(info, role: role, max_tokens: max_tokens)
                  end
        return content if content.is_a?(Hash) && content[:ok] == false && content[:artifact].nil?

        text = content[:content].to_s.strip
        if text.empty?
          return decline(
            reason: :perception_insufficient,
            message: "#{@family_name} returned an empty perception",
            manifest: manifest
          )
        end

        anchors = extract_anchors(text)
        if info[:chunk]
          anchors = [default_anchor(info)] + anchors
        elsif anchors.empty?
          anchors = [default_anchor(info)]
        end
        anchors = anchors.uniq
        artifact = perception_artifact(info, text, anchors)
        decision = Runes::Swarm::Decision.new(status: :accept, reason_code: :ok, body: text)
        envelope = manifest.nil? ? nil : Runes::Swarm::Envelope.stamp(
          manifest: manifest, decision: decision, body: text
        )

        AdapterSupport.envelope_result(
          content,
          family: result_family,
          modalities: definition[:modalities].map(&:to_s),
          extra: {
            artifact: artifact,
            anchors: anchors,
            source_sha256: info[:sha256],
            decision: decision,
            envelope: envelope,
            role: role
          }
        )
      end

      def available?
        return @backend.available? if @mode == :server
        return @backend.available? if @command_given
        return false unless File.file?(@cli_path)
        if AdapterSupport.path_like?(@model_name) &&
           !File.exist?(AdapterSupport.expanded_path(@model_name))
          return false
        end

        true
      end

      def availability_error
        return @backend.availability_error if @mode == :server
        return @backend.availability_error if @command_given
        return "media CLI not found: #{@cli_path}" unless File.file?(@cli_path)
        if AdapterSupport.path_like?(@model_name) &&
           !File.exist?(AdapterSupport.expanded_path(@model_name))
          return "media model path not found: #{@model_name}"
        end

        nil
      end

      def family
        @family ||= Runes::Swarm::ModelFamily.fetch(@model_name)
      rescue Runes::Swarm::ModelFamily::Invalid
        nil
      end

      def modalities
        definition[:modalities].map(&:to_s)
      end

      def result_family
        found = family
        found.nil? ? @model_name : found.model
      end

      def definition
        FAMILIES.fetch(@family_name)
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

        argv = @command_given ? @command : build_command('__INPUT__', @max_tokens, nil)
        CommandModel.new(
          command: argv,
          timeout_s: @timeout_s,
          cleaner: ->(text) { AdapterSupport.clean_output(text) },
          model_name: @model_name,
          runner: @runner
        )
      end

      def build_command(path, max_tokens, chunk_info)
        argv = [
          @python, @cli_path,
          '--family', @family_name.to_s,
          '--model', @model_name,
          '--input', path.to_s,
          '--max-tokens', max_tokens.to_s
        ]
        if chunk_info
          argv += ['--chunk-offset', chunk_info[:offset].to_s]
          argv += ['--chunk-length', chunk_info[:length].to_s]
        end
        argv
      end

      def command_call(info, role:, max_tokens:)
        model = CommandModel.new(
          command: build_command(info[:path], max_tokens || @max_tokens, info[:chunk]),
          timeout_s: @timeout_s,
          cleaner: ->(text) { AdapterSupport.clean_output(text) },
          model_name: @model_name,
          runner: @runner
        )
        result = model.call(perception_prompt(info), role: role)
        AdapterSupport.envelope_result(result, family: result_family, modalities: modalities)
      end

      def server_call(info, role:)
        result = @backend.call(perception_prompt(info), role: role)
        AdapterSupport.envelope_result(result, family: result_family, modalities: modalities)
      end

      def perception_prompt(info)
        chunk = info[:chunk] ? " (chunk #{info[:chunk][:offset]},#{info[:chunk][:length]})" : ''
        <<~PROMPT
          Perceive this #{info[:modality]} artifact and return a concise
          perception report as plain text: one observation per line, each with
          its resolvable anchor (page/box/time/frame) in parentheses, e.g.
          `Q3 bar reads 25 (image:1)`. Do not return JSON. Do not answer the
          task or judge it.

          Source: #{info[:path]}#{chunk}
          sha256: #{info[:sha256]}
        PROMPT
      end

      def source_info(input, modality: nil, chunk: nil)
        if input.is_a?(Array)
          raise ArgumentError, 'media adapter: one media input per call' if input.size > 1

          input = input.first
        end
        if input.nil? || input.to_s.strip.empty?
          return decline_info(needs_reason, "no #{@family_name} media supplied")
        end

        if input.is_a?(Hash)
          hash = AdapterSupport.stringify_keys(input)
          path = hash['path'] || hash['file'] || hash['input']
          modality ||= hash['modality']&.to_s&.to_sym
          chunk ||= hash['chunk'] || chunk_from_hash(hash)
        else
          path = input.to_s
        end

        return decline_info(needs_reason, "no #{@family_name} media supplied") if path.to_s.strip.empty?

        expanded = AdapterSupport.expanded_path(path)
        return decline_info(needs_reason, "unreadable media #{path}") unless File.file?(expanded)
        return decline_info(needs_reason, "unreadable media #{path}") unless File.readable?(expanded)

        chunk_info = normalize_chunk(chunk)
        {
          path: expanded,
          modality: normalize_modality(modality) || infer_modality(path),
          kind: kind_for(path),
          sha256: AdapterSupport.file_sha256(expanded),
          chunk: chunk_info
        }
      end

      def normalize_modality(value)
        return nil if value.nil?

        case value.to_s.to_sym
        when :document, :chart, :screen then :image
        when :audio_video, :av then :video
        else value.to_s.to_sym
        end
      end

      def chunk_from_hash(hash)
        return nil unless hash.key?('offset') || hash.key?('length')

        { 'offset' => hash['offset'], 'length' => hash['length'] }
      end

      def normalize_chunk(value)
        return nil if value.nil?

        if value.is_a?(Array)
          offset, length = value
          return { offset: offset.to_i, length: length.to_i }
        end
        if value.is_a?(Hash)
          hash = AdapterSupport.stringify_keys(value)
          return {
            offset: (hash['offset'] || hash['start'] || 0).to_i,
            length: (hash['length'] || hash['size'] || 0).to_i
          }
        end
        nil
      end

      def infer_modality(path)
        extension = File.extname(path.to_s).downcase
        return :audio if AUDIO.include?(extension)
        return :image if IMAGE.include?(extension)
        return :video if VIDEO.include?(extension)

        case @family_name
        when :audio then :audio
        when :omni then :video
        else :image
        end
      end

      def kind_for(path)
        extension = File.extname(path.to_s).downcase
        return 'document' if extension == '.pdf'
        return 'image' if IMAGE.include?(extension)
        return 'video' if VIDEO.include?(extension)
        return 'audio' if AUDIO.include?(extension)

        'media'
      end

      def extract_anchors(text)
        found = text.to_s.scan(ANCHOR).map(&:strip)
        found.concat(text.to_s.scan(TIME_ANCHOR))
        found.uniq
      end

      def default_anchor(info)
        chunk = info[:chunk]
        case info[:modality]
        when :audio
          "time:#{chunk ? chunk[:offset] : 0}"
        when :video
          "frame:#{chunk ? chunk[:offset] : 0}"
        else
          info[:kind] == 'document' ? 'page:1' : 'image:1'
        end
      end

      def perception_artifact(info, text, anchors)
        artifact = {
          'schema' => 'perception.v1',
          'modality' => info[:modality].to_s,
          'modalities' => artifact_modalities(info),
          'source' => info[:path],
          'source_sha256' => info[:sha256],
          'anchors' => anchors,
          'content' => text,
          'family' => @family_name.to_s,
          'model' => @model_name,
          'kind' => info[:kind],
          'provenance' => {
            'source' => info[:path],
            'source_sha256' => info[:sha256]
          }
        }
        artifact['chunk'] = {
          'offset' => info[:chunk][:offset],
          'length' => info[:chunk][:length]
        } if info[:chunk]
        artifact
      end

      def artifact_modalities(info)
        if @family_name == :omni && %i[audio video].include?(info[:modality])
          %w[audio video]
        else
          [info[:modality].to_s]
        end
      end

      def decline_info(reason, message)
        { decline: true, reason: reason, message: message }
      end

      def needs_reason
        case @family_name
        when :vision then :needs_vision
        when :audio then :needs_audio
        when :omni then :needs_omni
        else :needs_perception
        end
      end

      def decline(reason:, message:, manifest: nil)
        decision = Runes::Swarm::Decision.new(
          status: :decline, reason_code: reason, message: message
        )
        envelope = manifest.nil? ? nil : Runes::Swarm::Envelope.stamp(
          manifest: manifest, decision: decision, body: ''
        )
        AdapterSupport.failure(
          :declined,
          message,
          family: result_family,
          modalities: modalities,
          extra: { decision: decision, envelope: envelope, artifact: nil }
        )
      end

      def integer!(value, field)
        unless value.is_a?(Integer) && !value.negative?
          raise ArgumentError, "media adapter: #{field} must be a non-negative Integer, got #{value.inspect}"
        end

        value
      end
    end
  end
end
