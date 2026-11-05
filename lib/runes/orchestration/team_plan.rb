# frozen_string_literal: true

require_relative '../json_facade'
require_relative '../sha256_facade'
require_relative '../swarm/model_family'
require_relative '../swarm/registry'
require_relative 'shape'

module Runes
  module Orchestration
    # The Ruby planner.
    #
    # The model never sees a plan, and never writes one. This object is the
    # ordered micro-step DAG for one shape, the unique anchors a parallel call
    # is allowed to touch, and the acceptance checks the verifier will run.
    #
    #   plan = TeamPlan.build(shape: :answer_lite, task: task,
    #                         evidence: evidence, registry: registry)
    #   plan.steps.map(&:role) # => [:answerer, :judge, :reviewer, :verifier]
    #   plan.to_h              # => plan.v1
    class TeamPlan
      class Invalid < ArgumentError; end

      SCHEMA = 'plan.v1'
      DEFAULT_BUDGETS = { calls: 8, steps: 12, wall_s: 300 }.freeze
      DEFAULT_THRESHOLDS = {
        'accept_support' => 0.80,
        'accept_contradiction' => 0.10,
        'repair_support' => 0.30,
        'decline_support' => 0.30,
        'decline_contradiction' => 0.50,
        'select_support' => 0.80,
        'select_margin' => 0.15,
        'merge_support' => 0.70
      }.freeze

      ANCHOR_NAMES = %i[proposal_a proposal_b review repair].freeze
      ANCHOR_PREFIX = '[['
      ANCHOR_SUFFIX = ']]'

      # One ordered step. `agent_id` is resolved from the registry when it is
      # available; `capabilities` and `schema` are the manifest's, not a
      # model's claim. Deterministic roles are `kind: :control`.
      class Step
        attr_reader :role, :phase, :agent_id, :capabilities, :schema, :anchors,
                    :kind, :optional

        def initialize(role:, phase:, agent_id: nil, capabilities: [], schema: nil,
                       anchors: [], kind: :model, optional: false)
          @role = role.to_s.to_sym
          @phase = phase.to_s.to_sym
          @agent_id = agent_id&.to_s
          @capabilities = Array(capabilities).map(&:to_s).freeze
          @schema = schema&.to_s
          @anchors = Array(anchors).map(&:to_s).freeze
          @kind = kind.to_s.to_sym
          @optional = optional ? true : false
          freeze
        end

        def model?
          @kind == :model
        end

        def control?
          @kind == :control
        end

        def perception?
          @kind == :perception
        end

        def to_h
          {
            'role' => role.to_s,
            'phase' => phase.to_s,
            'agent_id' => agent_id,
            'capabilities' => capabilities,
            'schema' => schema,
            'anchors' => anchors,
            'kind' => kind.to_s,
            'optional' => optional
          }
        end

        def inspect
          "#<#{self.class.name} #{phase}/#{role} agent=#{agent_id.inspect} kind=#{kind}>"
        end
      end

      attr_reader :shape, :steps, :anchors, :acceptance, :budgets, :registry,
                  :task_text, :task_sha, :evidence_sha, :media, :decline_reason,
                  :decline_message

      def self.build(shape:, task: nil, evidence: nil, media: nil, registry: nil,
                     budgets: nil, calibration: nil, checks: nil)
        new(
          shape: shape, task: task, evidence: evidence, media: media,
          registry: registry, budgets: budgets, calibration: calibration,
          checks: checks
        )
      end

      def initialize(shape:, task: nil, evidence: nil, media: nil, registry: nil,
                     budgets: nil, calibration: nil, checks: nil)
        @shape = normalize_shape!(shape)
        @registry = registry
        @profile = Shape.normalize_profile(task)
        @task_text = build_task_text(task)
        @task_sha = Runes::SHA256.hex(@task_text)
        @evidence_sha = Runes::SHA256.hex(canonical(evidence))
        @media = normalize_media(media)
        @budgets = normalize_budgets(budgets)
        @anchors = build_anchors
        @checks = normalize_checks(checks || task_checks(task))
        @thresholds = normalize_thresholds(calibration)
        @decline_reason = nil
        @decline_message = nil
        @steps = []

        validate_shape!
        @acceptance = build_acceptance
        @steps = build_steps.freeze
        freeze
      end

      def declined?
        @decline_reason != nil
      end

      def model_steps
        @steps.select(&:model?)
      end

      def perception_steps
        @steps.select(&:perception?)
      end

      def steps_for_role(role)
        @steps.select { |step| step.role == role.to_s.to_sym }
      end

      def anchors_for(name)
        @anchors.fetch(name.to_sym)
      end

      def to_h
        {
          'schema' => SCHEMA,
          'shape' => @shape.to_s,
          'task_sha' => @task_sha,
          'evidence_sha' => @evidence_sha,
          'media' => @media,
          'anchors' => @anchors.each_with_object({}) { |(key, value), out| out[key.to_s] = value },
          'steps' => @steps.map(&:to_h),
          'acceptance' => @acceptance,
          'budgets' => @budgets,
          'declined' => declined?,
          'decline_reason' => @decline_reason&.to_s,
          'decline_message' => @decline_message
        }
      end

      # A compact Markdown rendering for `plan.md`. It contains every anchor
      # exactly once, so the conductor can prove a parallel writer did not
      # move or duplicate one.
      def to_markdown
        lines = []
        lines << '# plan.v1'
        lines << ''
        lines << "shape: #{@shape}"
        lines << "task_sha: #{@task_sha}"
        lines << "evidence_sha: #{@evidence_sha}"
        lines << ''
        lines << '## steps'
        @steps.each_with_index do |step, index|
          lines << "#{index + 1}. #{step.phase}: #{step.role}" \
                   "#{step.agent_id ? " (#{step.agent_id})" : ''}" \
                   " [#{step.schema || 'n/a'}] #{step.kind}"
        end
        lines << ''
        lines << '## anchors'
        ANCHOR_NAMES.each { |name| lines << @anchors.fetch(name) }
        lines << ''
        lines << '## acceptance'
        lines << Runes::Json.generate(@acceptance)
        lines << ''
        lines << '## budgets'
        lines << Runes::Json.generate(@budgets)
        lines << ''
        lines.join("\n")
      end

      def inspect
        "#<#{self.class.name} shape=#{@shape} steps=#{@steps.size} declined=#{declined?}>"
      end

      private

      def normalize_shape!(value)
        shape = Shape.normalize(value)
        if shape.nil?
          raise Invalid, "team plan: unknown shape #{value.inspect} (known: #{Shape::SHAPES.join(', ')})"
        end

        shape
      end

      def validate_shape!
        shape = Shape.normalize(@shape)
        return if @registry.nil?
        return if Shape.viable?(shape, @registry, modality: shape_modality, profile: @profile)

        @decline_reason = :no_route
        @decline_message = missing_requirements_message(shape)
      end

      def missing_requirements_message(shape)
        role = Shape.perception_role(shape)
        if role && !Shape.all_by_role(@registry, role).any?
          return "shape #{shape} requires the #{role} role"
        end
        if shape == :answer_full && Shape.all_by_role(@registry, :ideator).size < 2
          return 'shape answer_full requires two contracted ideators'
        end
        if shape == :escalate && Shape.all_by_role(@registry, :escalation).empty?
          return 'escalation was requested but no escalation role is configured'
        end

        required = Shape.required_roles(shape, profile: @profile)
        missing = required.reject { |item| Shape.all_by_role(@registry, item).any? }
        return "shape #{shape} requires #{missing.map(&:to_s).join(', ')}" unless missing.empty?

        "shape #{shape} has no viable local route"
      end

      def shape_modality
        first = @media.first
        return nil if first.nil?

        first['modality']&.to_sym
      end

      def build_steps
        return [] if declined?

        case @shape
        when :decide
          [
            model_step(:judge, :judge, optional: true),
            control_step(:verifier, :verify, schema: 'violations.v1')
          ]
        when :answer_lite
          text_steps(include_ideation: false)
        when :answer_full
          text_steps(include_ideation: true)
        when :see, :hear, :watch
          [perception_step] + text_steps(include_ideation: false)
        when :escalate
          [escalation_step]
        else
          []
        end
      end

      def perception_step
        role = Shape.perception_role(@shape)
        manifest = first_manifest(role)
        modality = Shape.default_modality(@shape)
        Step.new(
          role: role,
          phase: :perceive,
          agent_id: manifest&.agent_id,
          capabilities: manifest&.capacity&.can,
          schema: Runes::Swarm::ModelFamily.schema_for(role),
          anchors: [@anchors[:review]],
          kind: :perception
        )
      end

      def text_steps(include_ideation:)
        steps = []
        if include_ideation
          ideators = ordered_ideators
          ideators.each_with_index do |manifest, index|
            steps << Step.new(
              role: :ideator,
              phase: index.zero? ? :ideate_direct : :ideate_alternative,
              agent_id: manifest.agent_id,
              capabilities: manifest.capacity.can,
              schema: Runes::Swarm::ModelFamily.schema_for(:ideator),
              anchors: [@anchors[index.zero? ? :proposal_a : :proposal_b]],
              kind: :model
            )
          end
          steps << judge_step(:select, optional: false)
        end

        steps << model_step(:answerer, :solve)
        steps << model_step(:critic, :critique) if include_ideation
        steps << judge_step(:review, optional: false)
        steps << control_step(:reviewer, :review, schema: 'review.v1')
        steps << model_step(:repairer, :repair, optional: true, anchors: [@anchors[:repair]])
        steps << control_step(:verifier, :verify, schema: 'violations.v1')
        steps << model_step(:finalizer, :finalize, optional: true)
        steps
      end

      def judge_step(phase, optional:)
        Step.new(
          role: :judge,
          phase: phase,
          agent_id: first_manifest(:judge)&.agent_id,
          capabilities: first_manifest(:judge)&.capacity&.can || %w[score_support choose_proposal decline],
          schema: 'verdict.v1',
          anchors: [phase == :review ? @anchors[:review] : @anchors[:proposal_a]],
          kind: :model,
          optional: optional
        )
      end

      def escalation_step
        manifest = first_manifest(:escalation)
        Step.new(
          role: :escalation,
          phase: :escalate,
          agent_id: manifest&.agent_id,
          capabilities: manifest&.capacity&.can || %w[answer reason decline],
          schema: 'answer.v1',
          anchors: [],
          kind: :model
        )
      end

      def model_step(role, phase, optional: false, anchors: [])
        manifest = first_manifest(role)
        return control_step(role, phase, schema: Runes::Swarm::ModelFamily.schema_for(role),
                                              optional: optional) if manifest.nil?

        Step.new(
          role: role,
          phase: phase,
          agent_id: manifest.agent_id,
          capabilities: manifest.capacity.can,
          schema: Runes::Swarm::ModelFamily.schema_for(role),
          anchors: anchors,
          kind: :model,
          optional: optional
        )
      end

      def control_step(role, phase, schema:, optional: false)
        manifest = first_manifest(role)
        Step.new(
          role: role,
          phase: phase,
          agent_id: manifest&.agent_id,
          capabilities: manifest&.capacity&.can || [],
          schema: schema,
          anchors: [],
          kind: :control,
          optional: optional
        )
      end

      def first_manifest(role)
        Shape.all_by_role(@registry, role).first
      end

      def ordered_ideators
        Shape.all_by_role(@registry, :ideator).sort_by do |manifest|
          manifest.agent_id.end_with?('.direct') ? 0 : 1
        end.first(2)
      end

      def build_anchors
        ANCHOR_NAMES.each_with_object({}) do |name, out|
          out[name] = "#{ANCHOR_PREFIX}#{name.to_s.tr('_', '-')}#{ANCHOR_SUFFIX}"
        end.freeze
      end

      def build_acceptance
        {
          'checks' => @checks,
          'questions' => acceptance_questions,
          'thresholds' => @thresholds,
          'max_repair_rounds' => 1,
          'require_citation' => @checks.key?('must_cite') || @checks.key?(:must_cite),
          'require_anchors' => Shape::PERCEPTION_SHAPES.include?(@shape),
          'finalizer_optional' => true
        }
      end

      def acceptance_questions
        questions = Array(@profile && @profile[:questions]).map { |entry| normalize_question(entry) }
        if @shape == :answer_full
          questions += [
            { 'id' => 'support_a', 'question' => 'How well does proposal A answer the task?', 'type' => 'probability' },
            { 'id' => 'support_b', 'question' => 'How well does proposal B answer the task?', 'type' => 'probability' },
            { 'id' => 'choice', 'question' => 'Which proposal should be used?',
              'type' => 'choice', 'choices' => %w[a b merge neither] }
          ]
        end
        questions += [
          { 'id' => 'support', 'question' => 'Is every claim supported by the evidence?', 'type' => 'probability' },
          { 'id' => 'contradiction', 'question' => 'Does the evidence contradict a claim?', 'type' => 'probability' },
          { 'id' => 'sufficiency', 'question' => 'Is the evidence sufficient for the task?', 'type' => 'probability' }
        ]
        questions.uniq { |entry| entry['id'] }
      end

      def normalize_question(entry)
        case entry
        when String
          { 'id' => "q#{Runes::SHA256.hex(entry)[0, 8]}", 'question' => entry, 'type' => 'probability' }
        when Hash
          hash = entry.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
          hash['id'] = (hash['id'] ||
                        "q#{Runes::SHA256.hex(hash['question'].to_s)[0, 8]}").to_s
          hash['question'] = (hash['question'] || hash['text']).to_s
          hash['type'] ||= 'probability'
          hash
        else
          { 'id' => 'q', 'question' => entry.to_s, 'type' => 'probability' }
        end
      end

      def normalize_thresholds(calibration)
        out = DEFAULT_THRESHOLDS.dup
        return out if calibration.nil?

        hash = calibration.respond_to?(:to_h) ? calibration.to_h : calibration
        return out unless hash.is_a?(Hash)

        hash.each do |key, value|
          normalized = key.to_s
          number = numeric(value)
          out[normalized] = number unless number.nil?
        end
        out
      end

      def normalize_checks(value)
        return {} if value.nil?
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, entry), out| out[key.to_s] = entry }
      end

      def task_checks(task)
        return nil unless task.is_a?(Hash)

        task[:checks] || task['checks']
      end

      def normalize_budgets(value)
        hash = value.nil? ? {} : (value.respond_to?(:to_h) ? value.to_h : value)
        out = {}
        DEFAULT_BUDGETS.each do |key, default|
          raw = hash[key] || hash[key.to_s]
          out[key.to_s] = raw.nil? ? default : Integer(raw)
        end
        out
      rescue ArgumentError, TypeError
        raise Invalid, "team plan: budgets must contain integer values, got #{value.inspect}"
      end

      def normalize_media(value)
        entries = value.is_a?(Array) ? value : [value]
        entries.compact.map do |entry|
          if entry.is_a?(Hash)
            hash = entry.each_with_object({}) { |(key, item), out| out[key.to_s] = item }
            path = hash['path'] || hash['file'] || hash['input']
            modality = hash['modality']
            {
              'path' => path&.to_s,
              'modality' => modality.nil? ? infer_modality(path) : Shape.normalize_modality(modality).to_s,
              'sha256' => hash['sha256'] || hash['source_sha256']
            }
          else
            path = entry.to_s
            { 'path' => path, 'modality' => infer_modality(path).to_s, 'sha256' => nil }
          end
        end
      end

      def infer_modality(path)
        extension = File.extname(path.to_s).downcase
        return :audio if %w[.wav .mp3 .m4a .flac .ogg .aac .opus .aiff .aif].include?(extension)
        return :video if %w[.mp4 .mov .mkv .webm .avi .m4v].include?(extension)
        return :image if %w[.png .jpg .jpeg .gif .webp .bmp .tiff .tif .pdf].include?(extension)

        :image
      end

      def build_task_text(task)
        return '' if task.nil?
        return task.to_s unless task.is_a?(Hash)

        hash = task.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        text = hash['question'] || hash['task'] || hash['prompt'] || hash['text']
        return text.to_s unless text.nil?

        Runes::Json.generate(task)
      end

      def canonical(value)
        case value
        when Hash, Array then Runes::Json.generate(value)
        else value.to_s
        end
      rescue StandardError
        value.inspect
      end

      def numeric(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)

        text = value.to_s.strip
        return nil unless text.match?(/\A-?\d+(?:[.,]\d+)?\z/)

        text.tr(',', '.').to_f
      end
    end
  end
end
