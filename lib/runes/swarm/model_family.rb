# frozen_string_literal: true

module Runes
  module Swarm
    # The static facts about an LFM3 checkpoint, and the only place that
    # decides which model a role may use.
    #
    # The previous contract hardcoded `LiquidAI/LFM3-1.7B` for every
    # model-backed role. That made a vision or audio manifest either
    # impossible or a lie. A role now names a model, and the family table
    # says whether that pairing is legal, what the model can perceive, how
    # much context it has, and whether it emits an envelope or gets one
    # stamped by the adapter.
    class ModelFamily
      class Invalid < ArgumentError; end

      RUBY = 'ruby'
      EXTERNAL = 'external'

      TEXT_MODELS = %w[LiquidAI/LFM3-1.7B LiquidAI/LFM3-1.7B-Base].freeze
      D1_MODELS = %w[LiquidAI/d1-2B LiquidAI/d1-Omni-2B].freeze

      DEFINITIONS = {
        RUBY => {
          modalities: %i[text],
          context_tokens: 262_144,
          output_modes: %i[control],
          envelope_mode: :stamp,
          generates_tokens: false,
          structured: true,
          known_limits: ['no model call', 'no prose']
        },
        EXTERNAL => {
          modalities: %i[text],
          context_tokens: 262_144,
          output_modes: %i[text],
          envelope_mode: :echo,
          generates_tokens: true,
          structured: false,
          known_limits: ['operator-configured endpoint', 'never a silent fallback']
        },
        'LiquidAI/LFM3-1.7B' => {
          modalities: %i[text],
          context_tokens: 262_144,
          output_modes: %i[text],
          envelope_mode: :echo,
          generates_tokens: true,
          structured: false,
          known_limits: ['no agentic coding', 'no complex multi-step reasoning', 'no planning']
        },
        'LiquidAI/LFM3-1.7B-Base' => {
          modalities: %i[text],
          context_tokens: 262_144,
          output_modes: %i[text],
          envelope_mode: :echo,
          generates_tokens: true,
          structured: false,
          known_limits: ['adapter substrate only', 'requires a non-nil adapter_sha256']
        },
        'LiquidAI/LFM3-VL-2B' => {
          modalities: %i[text image video],
          context_tokens: 131_072,
          output_modes: %i[text],
          envelope_mode: :stamp,
          generates_tokens: true,
          structured: false,
          known_limits: ['no coding', 'no multi-turn chat', 'no complex reasoning']
        },
        'LiquidAI/LFM3-Audio-2B' => {
          modalities: %i[text audio],
          context_tokens: 32_768,
          output_modes: %i[text],
          envelope_mode: :stamp,
          generates_tokens: true,
          structured: false,
          known_limits: ['32K context', 'voice chat is English-only', 'no long-context reasoning']
        },
        'LiquidAI/LFM3-Omni-2B' => {
          modalities: %i[text image video audio],
          context_tokens: 32_768,
          output_modes: %i[text],
          envelope_mode: :stamp,
          generates_tokens: true,
          structured: false,
          known_limits: ['non-reasoning', '32K context', 'enable_thinking unsupported']
        },
        'LiquidAI/d1-2B' => {
          modalities: %i[text],
          context_tokens: 131_072,
          output_modes: %i[typed],
          envelope_mode: :stamp,
          generates_tokens: false,
          structured: true,
          known_limits: ['no chat', 'no prose', 'calibrated on its training distribution']
        },
        'LiquidAI/d1-Omni-2B' => {
          modalities: %i[text audio],
          context_tokens: 131_072,
          output_modes: %i[typed],
          envelope_mode: :stamp,
          generates_tokens: false,
          structured: true,
          known_limits: ['no transcription', 'no speech output', 'weaker than d1-2B on text']
        }
      }.freeze

      ROLE_MODELS = {
        conductor: [RUBY],
        planner: [RUBY],
        reviewer: [RUBY],
        verifier: [RUBY],
        escalation: [EXTERNAL],
        triage: D1_MODELS,
        judge: D1_MODELS,
        vision: ['LiquidAI/LFM3-VL-2B'],
        audio: ['LiquidAI/LFM3-Audio-2B'],
        omni: ['LiquidAI/LFM3-Omni-2B'],
        ideator: TEXT_MODELS,
        answerer: TEXT_MODELS,
        critic: TEXT_MODELS,
        repairer: TEXT_MODELS,
        finalizer: TEXT_MODELS,
        scout: TEXT_MODELS,
        generalist: TEXT_MODELS
      }.freeze

      ROLE_SCHEMAS = {
        conductor: 'decision.v1',
        planner: 'plan.v1',
        reviewer: 'review.v1',
        verifier: 'violations.v1',
        escalation: 'answer.v1',
        triage: 'verdict.v1',
        judge: 'verdict.v1',
        vision: 'perception.v1',
        audio: 'perception.v1',
        omni: 'perception.v1',
        ideator: 'proposal.v1',
        answerer: 'answer.v1',
        critic: 'critique.v1',
        repairer: 'answer.v1',
        finalizer: 'answer.v1',
        scout: 'evidence.v1',
        generalist: 'answer.v1'
      }.freeze

      DETERMINISTIC_ROLES = %i[conductor planner reviewer verifier].freeze

      attr_reader :model, :modalities, :context_tokens, :output_modes,
                  :envelope_mode, :known_limits

      def self.fetch(model)
        key = model.to_s
        data = DEFINITIONS[key]
        if data.nil?
          # A packaging variant of a known checkpoint (e.g.
          # LiquidAI/LFM3-VL-2B-MLX-4bit) resolves to its base definition,
          # keeping the actual name so receipts record the quantization.
          base = key
          while base.include?('-') && data.nil?
            base = base.sub(/-[^-]*\z/, '')
            data = DEFINITIONS[base]
          end
        end
        raise Invalid, "model family: unknown model #{model.inspect} (known: #{DEFINITIONS.keys.join(', ')})" if data.nil?

        new(key, **data)
      end

      def self.models_for(role)
        ROLE_MODELS.fetch(role.to_s.to_sym) do
          raise Invalid, "model family: unknown role #{role.inspect}"
        end
      end

      def self.allowed?(role:, model:)
        models_for(role).include?(model.to_s)
      end

      def self.schema_for(role)
        ROLE_SCHEMAS.fetch(role.to_s.to_sym) do
          raise Invalid, "model family: unknown role #{role.inspect}"
        end
      end

      def self.deterministic?(role)
        DETERMINISTIC_ROLES.include?(role.to_s.to_sym)
      end

      def self.external?(role)
        role.to_s.to_sym == :escalation
      end

      def initialize(model, modalities:, context_tokens:, output_modes:,
                     envelope_mode:, generates_tokens:, structured:, known_limits:)
        @model = model.to_s.dup.freeze
        @modalities = symbols!(modalities, :modalities)
        @context_tokens = positive_integer!(context_tokens, :context_tokens)
        @output_modes = symbols!(output_modes, :output_modes)
        @envelope_mode = symbols!([envelope_mode], :envelope_mode).first
        @generates_tokens = generates_tokens ? true : false
        @structured = structured ? true : false
        @known_limits = Array(known_limits).map { |limit| limit.to_s.dup.freeze }.freeze

        unless %i[echo stamp].include?(@envelope_mode)
          raise Invalid, "model family: envelope_mode must be :echo or :stamp"
        end

        freeze
      end

      def generates_tokens?
        @generates_tokens
      end

      def structured?
        @structured
      end

      def stamp?
        envelope_mode == :stamp
      end

      def echo?
        envelope_mode == :echo
      end

      def accepts_modality?(modality)
        modalities.include?(modality.to_s.to_sym)
      end

      def to_h
        {
          'model' => model,
          'modalities' => modalities.map(&:to_s),
          'context_tokens' => context_tokens,
          'output_modes' => output_modes.map(&:to_s),
          'envelope_mode' => envelope_mode.to_s,
          'generates_tokens' => generates_tokens?,
          'structured' => structured?,
          'known_limits' => known_limits
        }
      end

      def ==(other)
        other.is_a?(ModelFamily) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def inspect
        "#<#{self.class.name} #{model} modalities=#{modalities.inspect} context=#{context_tokens}>"
      end

      private

      def symbols!(value, field)
        array = Array(value)
        raise Invalid, "model family: #{field} must not be empty" if array.empty?

        array.map do |entry|
          symbol = entry.to_s.to_sym
          raise Invalid, "model family: #{field} contains an empty entry" if symbol.to_s.empty?

          symbol
        end.uniq.freeze
      end

      def positive_integer!(value, field)
        unless value.is_a?(Integer) && value.positive?
          raise Invalid, "model family: #{field} must be a positive Integer, got #{value.inspect}"
        end

        value
      end
    end
  end
end
