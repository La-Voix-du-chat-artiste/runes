# frozen_string_literal: true

require_relative '../json_facade'
require_relative '../sha256_facade'
require_relative '../swarm/registry'
require_relative '../swarm/model_family'
require_relative '../swarm/capacity'

module Runes
  module Orchestration
    # The shape router.
    #
    # A shape is selected from the triage verdict, the task profile and the
    # registry. The model never selects its own shape, and a missing required
    # role or modality is an escalation/decline, never a silent downgrade to a
    # cheaper shape.
    module Shape
      SHAPES = %i[
        decide answer_lite answer_full see hear watch escalate
      ].freeze

      ALIASES = {
        'decide' => :decide,
        'decision' => :decide,
        'answer-lite' => :answer_lite,
        'answer_lite' => :answer_lite,
        'lite' => :answer_lite,
        'answer-full' => :answer_full,
        'answer_full' => :answer_full,
        'full' => :answer_full,
        'see' => :see,
        'vision' => :see,
        'hear' => :hear,
        'audio' => :hear,
        'watch' => :watch,
        'omni' => :watch,
        'escalate' => :escalate,
        'escalation' => :escalate
      }.freeze

      PERCEPTION_SHAPES = %i[see hear watch].freeze

      TEXT_ROLES = {
        decide: [],
        answer_lite: %i[answerer judge reviewer verifier],
        answer_full: %i[ideator judge answerer critic reviewer verifier]
      }.freeze

      OPTIONAL_ROLES = {
        decide: %i[judge verifier],
        answer_lite: %i[repairer finalizer],
        answer_full: %i[repairer finalizer],
        see: %i[repairer finalizer],
        hear: %i[repairer finalizer],
        watch: %i[repairer finalizer],
        escalate: []
      }.freeze

      PERCEPTION_ROLE = {
        see: :vision,
        hear: :audio,
        watch: :omni
      }.freeze

      MODALITY_ALIASES = {
        'image' => :image, 'picture' => :image, 'photo' => :image,
        'document' => :image, 'pdf' => :image, 'chart' => :image,
        'screen' => :image, 'screenshot' => :image,
        'audio' => :audio, 'speech' => :audio, 'sound' => :audio,
        'voice' => :audio, 'call' => :audio,
        'video' => :video, 'movie' => :video, 'clip' => :video,
        'audio_video' => :video, 'av' => :video, 'audio-video' => :video,
        'text' => :text
      }.freeze

      module_function

      def normalize(value)
        text = value.to_s.strip.downcase.gsub(/\s+/, ' ')
        ALIASES[text] || ALIASES[text.tr('-', '_')]
      end

      def normalize_modality(value)
        return nil if value.nil?

        text = value.to_s.strip.downcase
        MODALITY_ALIASES[text] || text.to_sym
      end

      def known?(shape)
        SHAPES.include?(normalize(shape))
      end

      # Select exactly one shape. The return value is one of `SHAPES`;
      # `:escalate` also means "no local shape is viable".
      def select(triage_verdict, task_profile = nil, registry = nil)
        verdict = normalize_verdict(triage_verdict)
        profile = normalize_profile(task_profile)

        return :escalate if terminal_verdict?(verdict)
        return :escalate if unsafe?(verdict, profile)
        return :escalate if out_of_scope?(verdict, profile)

        modality = modality_of(verdict, profile)
        recommended = normalize(verdict[:shape] || profile[:shape])
        shape = recommended || default_shape(modality, verdict, profile)
        shape = adapt_to_modality(shape, modality, registry, profile)
        return :escalate if shape.nil?

        return shape if viable?(shape, registry, modality: modality, profile: profile)

        :escalate
      end

      # Roles a shape requires (control-plane triage excluded: it already ran).
      def required_roles(shape, profile: nil)
        name = normalize(shape) || shape.to_sym
        profile = normalize_profile(profile)
        base = TEXT_ROLES.fetch(name, [])
        return base unless PERCEPTION_SHAPES.include?(name)

        perception = PERCEPTION_ROLE.fetch(name)
        text = profile[:decision_only] ? TEXT_ROLES[:decide] : TEXT_ROLES[:answer_lite]
        [perception] + text
      end

      def optional_roles(shape)
        OPTIONAL_ROLES.fetch(normalize(shape) || shape.to_sym, [])
      end

      def viable?(shape, registry, modality: nil, profile: nil)
        name = normalize(shape) || shape.to_sym
        return false unless SHAPES.include?(name)

        return true if registry.nil?

        required_roles(name, profile: profile).each do |role|
          return false unless all_by_role(registry, role).any?
        end

        if name == :answer_full && all_by_role(registry, :ideator).size < 2
          return false
        end

        perception = PERCEPTION_ROLE[name]
        if perception
          role_modality = modality || default_modality(name)
          manifests = all_by_role(registry, perception)
          return false if manifests.empty?
          return false unless manifests.any? { |manifest| manifest.family.accepts_modality?(role_modality) }
        end

        if name == :decide
          # A decision still needs a typed triage role; the conductor already
          # ran it, but the shape must not claim a local path without one.
          return false if all_by_role(registry, :triage).empty?
        end

        true
      end

      def perception_role(shape)
        PERCEPTION_ROLE[normalize(shape) || shape.to_sym]
      end

      def text_shape(shape)
        name = normalize(shape) || shape.to_sym
        return name unless PERCEPTION_SHAPES.include?(name)

        :answer_lite
      end

      def default_modality(shape)
        case normalize(shape)
        when :see then :image
        when :hear then :audio
        when :watch then :video
        else :text
        end
      end

      def all_by_role(registry, role)
        registry.all_by_role(role)
      rescue Runes::Swarm::Registry::UnknownRole
        []
      end

      def normalize_verdict(value)
        hash = stringify(value)
        return {} unless hash

        decision = hash['decision']
        decision = stringify(decision) if decision.is_a?(Hash)
        {
          modality: first_present(hash, 'modality', 'media'),
          shape: first_present(hash, 'shape', 'recommended_shape', 'route'),
          intent: first_present(hash, 'intent', 'task_type'),
          scope: numeric(first_present(hash, 'scope', 'P(scope)')),
          risk: numeric(first_present(hash, 'risk', 'P(risk)')),
          sufficiency: numeric(first_present(hash, 'sufficiency', 'evidence_sufficiency')),
          unsafe: boolean(first_present(hash, 'unsafe', 'unsafe_request')),
          decision_status: first_present(decision || hash, 'status'),
          reason_code: first_present(decision || hash, 'reason_code'),
          decision: hash['decision'] || hash['status']
        }
      end

      def normalize_profile(value)
        hash = stringify(value) || {}
        modality = first_present(hash, 'modality', 'media')
        decision_only = boolean(first_present(hash, 'decision_only', 'decide'))
        decision_only ||= %w[classify classification extract extraction route routing
                             box count date score decide decision].include?(
                               first_present(hash, 'intent', 'task_type').to_s.downcase
                             )
        {
          modality: modality,
          shape: first_present(hash, 'shape', 'expected_shape'),
          intent: first_present(hash, 'intent', 'task_type'),
          risk: numeric(first_present(hash, 'risk')),
          ambiguity: numeric(first_present(hash, 'ambiguity')),
          multistep: boolean(first_present(hash, 'multistep', 'multi_step')),
          decision_only: decision_only,
          checks: hash['checks'],
          questions: hash['questions'] || hash['acceptance_questions']
        }
      end

      def default_shape(modality, verdict, profile)
        return :decide if profile[:decision_only]

        risky = [verdict[:risk], profile[:risk]].compact.max.to_f
        ambiguity = profile[:ambiguity].to_f
        if risky >= 0.60 || ambiguity >= 0.60 || profile[:multistep]
          return :answer_full
        end

        case modality
        when :image then :see
        when :audio then :hear
        when :video then :watch
        else :answer_lite
        end
      end

      def adapt_to_modality(shape, modality, registry, profile)
        return shape if modality.nil? || modality == :text

        case modality
        when :audio
          :hear
        when :video
          watch_viable?(registry) ? :watch : :see
        when :image
          :see
        else
          shape
        end
      end

      def watch_viable?(registry)
        return true if registry.nil?

        all_by_role(registry, :omni).any?
      end

      def modality_of(verdict, profile)
        value = verdict[:modality] || profile[:modality]
        return nil if value.nil? || value.to_s.strip.empty?

        normalize_modality(value)
      end

      def terminal_verdict?(verdict)
        status = verdict[:decision_status].to_s
        return true if %w[decline escalate].include?(status)
        return true if %w[decline escalate].include?(verdict[:decision].to_s)

        %i[out_of_scope unsafe_request needs_frontier needs_human].include?(
          verdict[:reason_code].to_s.to_sym
        )
      end

      def unsafe?(verdict, profile)
        return true if verdict[:unsafe]

        risk = verdict[:risk] || profile[:risk]
        !risk.nil? && risk >= 0.80
      end

      def out_of_scope?(verdict, profile)
        _ = profile
        scope = verdict[:scope]
        !scope.nil? && scope < 0.30
      end

      def numeric(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)

        text = value.to_s.strip
        return nil unless text.match?(/\A-?\d+(?:[.,]\d+)?\z/)

        text.tr(',', '.').to_f
      end

      def boolean(value)
        return value if [true, false].include?(value)

        %w[true yes 1 unsafe high].include?(value.to_s.strip.downcase)
      end

      def first_present(hash, *keys)
        return nil unless hash.is_a?(Hash)

        keys.each do |key|
          [key, key.to_s].each do |candidate|
            return hash[candidate] if hash.key?(candidate)
          end
        end
        nil
      end

      def stringify(value)
        return nil if value.nil?

        hash = value.respond_to?(:to_h) ? value.to_h : value
        return nil unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, entry), out| out[key.to_s] = entry }
      end
    end
  end
end
