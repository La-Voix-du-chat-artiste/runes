# frozen_string_literal: true

require_relative '../compat'
require_relative '../json_facade'
require_relative '../sha256_facade'
require_relative '../swarm'
require_relative '../llm/role_profile'
require_relative 'guards'
require_relative 'receipt'
require_relative 'violation'
require_relative 'shape'
require_relative 'team_plan'

module Runes
  module Orchestration
    # The supervised LFM3 team conductor.
    #
    # The model never sees a plan and never chooses a hop. The conductor runs
    # one micro-task per call, records a 14-gate checkpoint for every step,
    # stops on the first failed gate, routes declines/escalations instead of
    # retrying the same role, and lets the Ruby verifier own acceptance.
    class Conductor
      class Stop < StandardError
        attr_reader :status, :final, :decision, :error

        def initialize(status:, final: nil, decision: nil, error: nil)
          @status = status.to_sym
          @final = final
          @decision = decision
          @error = error
          super(error || status.to_s)
        end
      end

      class Result
        attr_reader :status, :shape, :final, :decision, :route, :checkpoints,
                    :violations, :receipt, :ledger, :error, :elapsed_s, :plan

        def initialize(status:, shape: nil, final: nil, decision: nil, route: [],
                       checkpoints: [], violations: [], receipt: nil, ledger: nil,
                       error: nil, elapsed_s: nil, plan: nil)
          @status = status.to_sym
          @shape = shape&.to_sym
          @final = final
          @decision = decision
          @route = route || []
          @checkpoints = checkpoints || []
          @violations = violations || []
          @receipt = receipt
          @ledger = ledger
          @error = error
          @elapsed_s = elapsed_s
          @plan = plan
        end

        def ok?
          %i[ok repaired].include?(status)
        end

        def control?
          %i[declined escalated].include?(status)
        end

        def calls
          receipt ? receipt.calls : []
        end

        def call_count
          calls.size
        end

        def unvalidated_hops
          route.count { |entry| entry['checkpoint'].nil? }
        end

        def to_h
          {
            'status' => status.to_s,
            'shape' => shape&.to_s,
            'final' => final,
            'decision' => decision&.to_h,
            'route' => route,
            'checkpoints' => checkpoints.map(&:to_h),
            'violations' => violations.map(&:to_h),
            'receipt' => receipt&.to_h,
            'error' => error,
            'elapsed_s' => elapsed_s,
            'unvalidated_hops' => unvalidated_hops
          }
        end
      end

      ANSWER = <<~TEXT
        Answer the task using only the validated evidence and perception.
        Cite the exact anchors you used. Never add a fact from general
        knowledge. If the requested value is absent, abstain explicitly.
      TEXT

      CRITIC = <<~TEXT
        Audit the candidate claim by claim against the validated evidence.
        Do not rewrite the answer. List unsupported or contradicted claims
        and, when a claim is contradicted, quote the evidence that does it.
      TEXT

      REPAIR = <<~TEXT
        Rewrite the answer to remove or replace exactly the unsupported
        claims. Preserve the citations that remain valid. Never add a fact,
        change the evidence, or start another round. If the evidence cannot
        support a claim, remove it or abstain.
      TEXT

      FINALIZE = <<~TEXT
        Rewrite the verified answer concisely. Preserve every citation and
        add no fact. If a concise rewrite would change the meaning, decline.
      TEXT

      IDEATE_DIRECT = <<~TEXT
        Propose the most direct approach to the task. State the invariant,
        cite the evidence that supports it, and list edge cases. Do not
        answer the task in final form; emit one proposal only.
      TEXT

      IDEATE_ALTERNATIVE = <<~TEXT
        Propose a genuinely different technique family from the direct
        proposal. Compare the tradeoffs and state any disconfirming evidence.
        Do not answer the task in final form; emit one proposal only.
      TEXT

      SILENT = /\A\s*\z/

      def initialize(registry:, ledger:, guards: nil, verifier: nil, broker: nil,
                     models: {}, profiles: {}, calibration: nil, max_calls: nil,
                     max_steps: 12, max_wall_s: nil, clock: nil, checks: nil,
                     task_profile: nil, shape: nil, finalize: true, escalation: nil,
                     require_evidence: false)
        raise ArgumentError, 'conductor: registry is required' if registry.nil?
        raise ArgumentError, 'conductor: ledger is required' if ledger.nil?

        @registry = registry
        @ledger = ledger
        @guards = guards
        @verifier = verifier
        @models = normalize_models(models)
        @profiles = profiles || {}
        @calibration = calibration
        @explicit_checks = checks
        @task_profile = task_profile || {}
        @forced_shape = shape.nil? ? nil : Shape.normalize(shape)
        @finalize = finalize ? true : false
        @escalation_option = escalation
        @require_evidence = require_evidence ? true : false

        @max_calls = Integer(max_calls || broker&.max_calls || 8)
        raise ArgumentError, 'conductor: max_calls must be non-negative' if @max_calls.negative?

        @max_steps = Integer(max_steps || 12)
        raise ArgumentError, 'conductor: max_steps must be positive' unless @max_steps.positive?

        @max_wall_s = max_wall_s.nil? ? broker&.max_wall_s : max_wall_s.to_f
        @clock = clock || -> { Runes::Compat.monotonic }
        @broker = broker || Runes::Swarm::CapacityBroker.new(
          max_calls: [@max_calls, 1].max, max_wall_s: @max_wall_s
        )

        @calls = 0
        @step_count = 0
        @route = []
        @checkpoints = []
        @violations = []
        @used_manifests = []
        @perception = []
        @proposals = []
        @calibration_records = []
        @test_status = nil
        @test_output = nil
        @review = nil
        @triage = nil
        @plan = nil
        @selected_shape = nil
        @repair_round = 0
        @verified_answer = nil
        @answer = nil
        @started = nil
        @finished = nil
      end

      def run(task:, evidence: nil, media: nil)
        @started = @clock.call
        @task = task
        @task_text = task_text(task)
        @evidence = evidence
        @media = normalize_media(media)
        @task_profile = merge_profile(@task_profile, Shape.normalize_profile(task))

        @ledger.write(:task, @task_text)
        @ledger.write_json(:evidence, evidence)
        @receipt = Runes::RunReceipt.new(
          run_id: @ledger.run_id,
          model: model_name,
          sampler: {},
          shape: @forced_shape
        )
        @ledger.update_manifest(
          'run_id' => @ledger.run_id,
          'model' => model_name,
          'task_sha' => Runes::SHA256.hex(@task_text),
          'evidence_sha' => Runes::SHA256.hex(Runes::Json.generate(evidence))
        )
        @ledger.append_transcript('run_started', model: model_name)

        execute
      rescue Stop => e
        finish(e.status, e.final, decision: e.decision, error: e.error)
      rescue StandardError => e
        finish(:error, nil, error: "#{e.class}: #{e.message}")
      end

      private

      # ---------------------------------------------------------------- loop

      def execute
        budget!(phase: :intake)
        require_evidence!

        triage = run_triage
        @triage = triage
        write_triage
        shape = select_shape(triage)
        @selected_shape = shape
        @receipt.instance_variable_set(:@shape, shape.to_s) if @receipt

        if shape == :escalate
          reason = triage_reason(triage) || :needs_frontier
          escalate!(reason, message: triage_message(triage))
        end

        @plan = TeamPlan.build(
          shape: shape,
          task: @task,
          evidence: @evidence,
          media: @media,
          registry: @registry,
          budgets: budgets,
          calibration: @calibration,
          checks: @explicit_checks
        )
        write_plan
        if @plan.declined?
          decline!(@plan.decline_reason || :no_route, @plan.decline_message)
        end

        case shape
        when :decide
          execute_decide(triage)
        when :answer_lite
          execute_text_shape(triage, full: false)
        when :answer_full
          execute_text_shape(triage, full: true)
        when :see, :hear, :watch
          perceive!
          execute_text_shape(triage, full: false)
        when :escalate
          escalate!(triage_reason(triage) || :needs_frontier)
        else
          decline!(:no_route, "shape #{shape.inspect} has no local route")
        end
      end

      # --------------------------------------------------------------- triage

      def run_triage
        manifest = triage_manifest
        decline!(:no_route, 'no triage role is configured') if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        decline!(:no_route, "no model is wired for #{manifest.agent_id}") if model.nil?

        # Triage classifies the request; it does not consume the media unless
        # the assigned triage family actually accepts that modality (the audio
        # triage model is the only one that does). Sending an image to a
        # text-only d1 is an avoidable out_of_modality decline.
        consumes = manifest.family.accepts_modality?(media_modality) ? media_modality : :text
        auth = authorize(manifest, task: triage_task(consumes), evidence: @evidence)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :triage, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        questions = triage_questions
        input = consumes == :text ? nil : media_path
        result = call_d1(manifest, triage_state, questions, media: input, phase: :triage)
        checkpoint = d1_checkpoint(manifest, result, phase: :triage, questions: questions)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        artifact = d1_artifact(result)
        triage = {
          artifact: artifact,
          decision: decision || accept_decision(d1_text(artifact)),
          manifest: manifest,
          result: result
        }
        # A triage decline stops before `select_shape` runs in `execute`; the
        # row still needs the shape the triage selected.
        @selected_shape ||= select_shape(triage)
        if decision&.escalate?
          escalate!(decision.reason_code, message: decision.message)
        elsif decision&.decline?
          route_decline!(decision, phase: :triage)
        end

        verify_probabilities!(artifact, checkpoint)
        triage
      end

      def triage_manifest
        candidates = all_by_role(:triage)
        return candidates.first if candidates.empty?

        modality = media_modality
        if modality == :audio
          audio = candidates.find { |manifest| manifest.family.accepts_modality?(:audio) }
          return audio unless audio.nil?
        end
        candidates.find { |manifest| manifest.base_model == 'LiquidAI/d1-2B' } || candidates.first
      end

      def triage_task(modality = :text)
        {
          'modality' => modality,
          'evidence' => @evidence.nil? || empty_evidence? ? 'optional' : 'required',
          'required' => [],
          'calibration' => @calibration
        }
      end

      def triage_state
        state = {
          'task' => @task_text,
          'evidence' => @evidence,
          'media' => media_summary,
          'profile' => @task_profile,
          'declared_capacities' => declared_capacities,
          'instruction' => 'Classify one request. Return typed probabilities, ' \
                           'the recommended shape and a scope decision.'
        }
        state['calibration'] = @calibration unless @calibration.nil?
        state
      end

      # The team's declared capacities, so the scope question is judged
      # against what the registry actually grants — not against a generic
      # notion of "in scope".
      def declared_capacities
        can = []
        cannot = []
        limits = []
        Array(@registry&.manifests).each do |manifest|
          can.concat(Array(manifest.capacity.can).map(&:to_s))
          cannot.concat(Array(manifest.capacity.cannot).map(&:to_s))
          limits.concat(Array(manifest.family&.known_limits).map(&:to_s))
        end
        {
          'roles' => Array(@registry&.roles).map(&:to_s).sort,
          'can' => can.uniq.sort,
          'cannot' => (cannot.uniq - can.uniq).sort,
          'known_limits' => limits.uniq.sort
        }
      end

      def triage_questions
        explicit = @task_profile[:questions] || @task_profile['triage_questions']
        return explicit if explicit.is_a?(Array) && !explicit.empty?

        [
          { 'id' => 'modality', 'question' => 'Which input modality does the request carry?',
            'type' => 'choice', 'choices' => %w[text image audio video] },
          { 'id' => 'intent', 'question' => 'What kind of task is this?',
            'type' => 'choice',
            'choices' => %w[answer classify extract route box count date score decide] },
          { 'id' => 'scope', 'question' => 'Is this task inside the declared capacities ' \
                                            'and known limits in the state?',
            'type' => 'probability' },
          { 'id' => 'risk', 'question' => 'How high is the risk or stakes of a wrong answer?',
            'type' => 'probability' },
          { 'id' => 'sufficiency', 'question' => 'Is the supplied evidence sufficient?',
            'type' => 'probability' },
          { 'id' => 'shape', 'question' => 'Which team shape should run?',
            'type' => 'choice',
            'choices' => %w[decide answer-lite answer-full see hear watch escalate] },
          { 'id' => 'unsafe', 'question' => 'Is the request unsafe or forbidden?',
            'type' => 'boolean' }
        ]
      end

      def triage_verdict(triage)
        artifact = triage[:artifact]
        {
          'modality' => verdict_value(artifact, 'modality'),
          'shape' => verdict_value(artifact, 'shape'),
          'intent' => verdict_value(artifact, 'intent'),
          'scope' => verdict_value(artifact, 'scope'),
          'risk' => verdict_value(artifact, 'risk'),
          'sufficiency' => verdict_value(artifact, 'sufficiency'),
          'unsafe' => verdict_value(artifact, 'unsafe'),
          'decision' => artifact['decision'] || artifact['status'],
          'reason_code' => artifact['reason_code'] || triage[:decision]&.reason_code
        }
      end

      def select_shape(triage)
        verdict = Shape.normalize_verdict(triage_verdict(triage))
        # Safety verdicts gate even a forced shape: an out-of-scope or unsafe
        # request must escalate/decline, never run the forced shape.
        return :escalate if Shape.terminal_verdict?(verdict)
        return :escalate if Shape.unsafe?(verdict, @task_profile)
        return :escalate if Shape.out_of_scope?(verdict, @task_profile)

        return @forced_shape unless @forced_shape.nil?

        Shape.select(triage_verdict(triage), @task_profile, @registry)
      end

      def triage_reason(triage)
        artifact = triage[:artifact]
        reason = artifact['reason_code'] || triage[:decision]&.reason_code
        reason = verdict_value(artifact, 'reason_code') if reason.nil?
        return nil if reason.nil? || reason.to_s.empty? || reason.to_s == 'ok'

        reason.to_s.to_sym
      end

      def triage_message(triage)
        triage[:decision]&.message || verdict_value(triage[:artifact], 'message')
      end

      def write_triage
        @ledger.write_json(:triage, {
          'artifact' => @triage[:artifact],
          'decision' => @triage[:decision]&.to_h,
          'agent_id' => @triage[:manifest]&.agent_id
        })
      end

      # ----------------------------------------------------------------- plan

      def write_plan
        text = @plan.to_markdown
        @ledger.write(:plan, text)
        verify_anchors!(@plan)

        checkpoint = add_checkpoint(
          phase: :plan, role: :planner, manifest: manifest_for(:planner),
          gates: control_gates(route: :pass), violations: [],
          decision: accept_decision(@plan.shape.to_s), call: nil
        )
        stop_on_failure!(checkpoint, nil)
      end

      def verify_anchors!(plan)
        text = plan.to_markdown
        missing = plan.anchors.values.reject do |anchor|
          text.scan(Regexp.new(Regexp.escape(anchor))).size == 1
        end
        return if missing.empty?

        checkpoint = add_checkpoint(
          phase: :plan, role: :planner, manifest: manifest_for(:planner),
          gates: control_gates(route: :fail),
          violations: [violation(:contract_invalid, "anchor is not unique: #{missing.first}")],
          decision: nil, call: nil
        )
        stop_on_failure!(checkpoint, nil)
      end

      # ------------------------------------------------------------ perception

      def perceive!
        steps = @plan.perception_steps
        if steps.empty?
          decline!(:needs_perception, "shape #{@plan.shape} has no perception step")
        end

        steps.each do |step|
          media = media_for(step.role)
          if media.nil?
            decline!(needs_reason(step.role), "no #{step.role} media was supplied")
          end

          manifest = manifest_for(step.role)
          decline!(:no_route, "no #{step.role} role is configured") if manifest.nil?

          model = model_for(step.role, manifest.agent_id)
          decline!(:no_route, "no model is wired for #{manifest.agent_id}") if model.nil?

          auth = authorize(manifest, task: perception_task(step.role, media),
                                      evidence: @evidence, modality: media[:modality])
          unless auth.accept?
            checkpoint = add_checkpoint(
              phase: :perceive, role: manifest.role, manifest: manifest,
              gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
              decision: auth, call: nil
            )
            stop_on_failure!(checkpoint, nil)
          end

          result = call_media(manifest, media, phase: :perceive)
          checkpoint = media_checkpoint(manifest, result, media: media, phase: :perceive)
          stop_on_failure!(checkpoint, result)

          artifact = result[:artifact]
          @perception << {
            'role' => manifest.role.to_s,
            'agent_id' => manifest.agent_id,
            'artifact' => artifact
          }
          @ledger.write_json(:perception, @perception)
          @ledger.append_transcript('perception_recorded', role: manifest.role.to_s,
                                    anchors: Array(artifact && artifact['anchors']).size)
        end

        judge_perception! unless @perception.empty?
      end

      def judge_perception!
        manifest = judge_manifest
        return if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        return if model.nil?

        auth = authorize(manifest, task: { 'modality' => :text, 'evidence' => 'optional' },
                                    evidence: @evidence, modality: :text)
        return unless auth.accept?

        state = {
          'task' => @task_text,
          'perception' => @perception.map { |entry| perception_text(entry) },
          'instruction' => 'Score whether the perception is sufficient for the task.'
        }
        questions = [
          { 'id' => 'sufficiency', 'question' => 'Is the perception sufficient?', 'type' => 'probability' },
          { 'id' => 'support', 'question' => 'Is the perception supported by its anchors?', 'type' => 'probability' }
        ]
        result = call_d1(manifest, state, questions, phase: :perception_judge)
        checkpoint = d1_checkpoint(manifest, result, phase: :perception_judge, questions: questions)
        stop_on_failure!(checkpoint, result)

        artifact = d1_artifact(result)
        sufficiency = numeric(verdict_value(artifact, 'sufficiency')) || 1.0
        record_calibration('perception', artifact, checkpoint)
        return if sufficiency >= 0.30

        decline!(:missing_evidence, "perception sufficiency #{sufficiency} is below 0.30")
      end

      def media_for(role)
        entries = @media
        return entries.first if entries.size == 1 && role == :omni

        desired =
          case role
          when :vision then %i[image video]
          when :audio then %i[audio]
          when :omni then %i[video audio image]
          else []
          end
        entries.find { |entry| desired.include?(entry[:modality]) } || entries.first
      end

      def perception_task(role, media)
        {
          'modality' => media[:modality],
          'evidence' => 'optional',
          'required' => [],
          'calibration' => @calibration,
          'role' => role.to_s
        }
      end

      # ------------------------------------------------------------- execution

      def execute_decide(triage)
        typed = !decision_questions.empty?
        final = typed ? typed_decision! : d1_text(triage[:artifact])
        decision = triage[:decision] || accept_decision(final)
        @answer = final
        @ledger.write(:final, final)

        if typed
          # A typed decision is still an artifact the benchmark can check. The
          # d1 call is stamp-mode, so the verifier gate is code, not prose.
          run_test!(final)
          if (@test_violations || []).any?(&:error?)
            checkpoint = add_checkpoint(
              phase: :verify, role: :verifier, manifest: manifest_for(:verifier),
              gates: control_gates(verifier: :fail), violations: @test_violations,
              decision: decision, call: nil
            )
            stop_on_failure!(checkpoint, nil)
          end
          checkpoint = add_checkpoint(
            phase: :verify, role: :verifier, manifest: manifest_for(:verifier),
            gates: control_gates(verifier: :pass), violations: [],
            decision: decision, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        else
          @ledger.write(:final_test_output, "- typed decision; no prose verifier\n")
          add_checkpoint(
            phase: :verify, role: :verifier, manifest: manifest_for(:verifier),
            gates: control_gates(verifier: :skip), violations: [],
            decision: decision, call: nil
          )
        end

        finish(:ok, final, decision: decision)
      end

      # Domain questions supplied by the caller turn `decide` into a typed d1
      # decision, rather than a second read of the triage verdict. Without them
      # the existing triage-only behaviour is unchanged.
      def decision_questions
        return [] unless @task.is_a?(Hash)

        value = @task['questions'] || @task[:questions]
        Array(value)
      end

      def typed_decision!
        manifest = judge_manifest || @triage&.dig(:manifest)
        if manifest&.requires_evidence? && (@evidence.nil? || empty_evidence?)
          manifest = @triage&.dig(:manifest) || manifest
        end
        decline!(:no_route, 'decide requires a d1 role') if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        decline!(:no_route, "no model is wired for #{manifest.agent_id}") if model.nil?

        questions = decision_questions
        auth = authorize(manifest, task: decision_task, evidence: @evidence, modality: :text)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :decide, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        state = {
          'task' => @task_text,
          'evidence' => @evidence,
          'instruction' => 'Answer each typed decision question. Do not write prose.'
        }
        result = call_d1(manifest, state, questions, phase: :decide)
        checkpoint = d1_checkpoint(manifest, result, phase: :decide, questions: questions)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        route_decline!(decision, phase: :decide) if decision&.decline? || decision&.escalate?

        artifact = d1_artifact(result)
        record_calibration('decide', artifact, checkpoint)
        d1_text(artifact)
      end

      def decision_task
        {
          'modality' => :text,
          'evidence' => @evidence.nil? || empty_evidence? ? 'optional' : 'required',
          'questions' => decision_questions.filter_map do |question|
            next unless question.is_a?(Hash)

            question['id'] || question[:id]
          end,
          'calibration' => @calibration
        }
      end

      def execute_text_shape(triage, full:)
        ideation = full ? ideate! : nil
        answer = solve!(ideation)
        @answer = answer
        run_test!(answer)
        critique = full ? criticize!(answer) : nil
        review = run_review!(answer, critique: critique)
        answer = repair!(answer, review) if review['decision'] == 'repair'
        @answer = answer
        verify!(answer)
        answer = finalize!(answer) if @finalize
        status = @repair_round.positive? ? :repaired : :ok
        finish(status, answer, decision: accept_decision(answer))
      end

      def ideate!
        manifests = ordered_ideators
        if manifests.size < 2
          decline!(:no_route, 'answer-full requires two contracted ideators')
        end

        proposals = []
        manifests.first(2).each_with_index do |manifest, index|
          model = model_for(manifest.role, manifest.agent_id)
          decline!(:no_route, "no model is wired for #{manifest.agent_id}") if model.nil?

          auth = authorize(manifest, task: solve_task, evidence: @evidence)
          unless auth.accept?
            checkpoint = add_checkpoint(
              phase: index.zero? ? :ideate_direct : :ideate_alternative,
              role: manifest.role, manifest: manifest, gates: gated(:budget),
              violations: [violation(auth.reason_code, auth.message)], decision: auth, call: nil
            )
            stop_on_failure!(checkpoint, nil)
          end

          anchor = @plan.anchors[index.zero? ? :proposal_a : :proposal_b]
          prompt = prompt_for(
            manifest,
            instruction: index.zero? ? IDEATE_DIRECT : IDEATE_ALTERNATIVE,
            task: @task_text,
            evidence: @evidence,
            perception: perception_packet,
            anchor: anchor
          )
          result = call_text(manifest, prompt,
                             phase: index.zero? ? :ideate_direct : :ideate_alternative)
          checkpoint = text_checkpoint(manifest, result,
                                       phase: index.zero? ? :ideate_direct : :ideate_alternative)
          stop_on_failure!(checkpoint, result)

          body = decision_body(result)
          proposal = {
            'id' => index.zero? ? 'a' : 'b',
            'agent_id' => manifest.agent_id,
            'anchor' => anchor,
            'body' => body,
            'sha256' => Runes::SHA256.hex(body)
          }
          proposals << proposal
          @proposals << proposal
          @ledger.write_json(:proposals, @proposals)
          @ledger.append_transcript('proposal_recorded', id: proposal['id'],
                                    agent_id: manifest.agent_id)
        end

        verify_anchors!(@plan)
        if proposals.map { |proposal| proposal['sha256'] }.uniq.size == 1
          raise Stop.new(status: :proposal_collapse, final: nil, decision: nil,
                         error: 'the two ideators returned identical proposals; only one is counted')
        end

        select_proposal!(proposals)
      end

      def select_proposal!(proposals)
        manifest = judge_manifest
        decline!(:no_route, 'answer-full requires a judge role') if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        decline!(:no_route, "no model is wired for #{manifest.agent_id}") if model.nil?

        auth = authorize(manifest, task: solve_task, evidence: @evidence)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :select, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        questions = [
          { 'id' => 'support_a', 'question' => 'How well does proposal A answer the task?',
            'type' => 'probability' },
          { 'id' => 'support_b', 'question' => 'How well does proposal B answer the task?',
            'type' => 'probability' },
          { 'id' => 'choice', 'question' => 'Which proposal should be used?',
            'type' => 'choice', 'choices' => %w[a b merge neither] }
        ]
        state = {
          'task' => @task_text,
          'evidence' => @evidence,
          'proposals' => proposals,
          'thresholds' => @plan.acceptance['thresholds'],
          'instruction' => 'Score each proposal and choose one, merge or neither.'
        }
        result = call_d1(manifest, state, questions, phase: :select)
        checkpoint = d1_checkpoint(manifest, result, phase: :select, questions: questions)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        route_decline!(decision, phase: :select) if decision&.decline? || decision&.escalate?

        artifact = d1_artifact(result)
        support_a = numeric(verdict_value(artifact, 'support_a')) || 0.0
        support_b = numeric(verdict_value(artifact, 'support_b')) || 0.0
        choice = verdict_value(artifact, 'choice').to_s.downcase
        thresholds = @plan.acceptance['thresholds']
        choice = choose_band(choice, support_a, support_b, thresholds)
        @calibration_records << {
          'phase' => 'select',
          'support_a' => support_a,
          'support_b' => support_b,
          'choice' => choice,
          'thresholds' => thresholds,
          'decision' => decision&.to_h,
          'artifact' => artifact
        }
        @ledger.write_json(:calibration, @calibration_records)

        {
          'choice' => choice,
          'proposals' => selected_proposals(choice, proposals),
          'support' => [support_a, support_b].max,
          'artifact' => artifact
        }
      end

      def choose_band(choice, support_a, support_b, thresholds)
        return choice if %w[merge neither].include?(choice)
        return choice if %w[a b].include?(choice) &&
                         (support_a - support_b).abs >= thresholds['select_margin'].to_f

        if support_a >= thresholds['merge_support'].to_f &&
           support_b >= thresholds['merge_support'].to_f
          return 'merge'
        end
        support_a >= support_b ? 'a' : 'b'
      end

      def selected_proposals(choice, proposals)
        case choice
        when 'a' then [proposals[0]]
        when 'b' then [proposals[1]]
        when 'merge' then proposals
        else []
        end
      end

      def solve!(ideation)
        manifest = manifest_for(:answerer)
        decline!(:no_route, 'no answerer role is configured') if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        decline!(:no_route, "no model is wired for #{manifest.agent_id}") if model.nil?

        auth = authorize(manifest, task: solve_task, evidence: @evidence)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :solve, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        prompt = prompt_for(
          manifest,
          instruction: ANSWER,
          task: @task_text,
          evidence: @evidence,
          perception: perception_packet,
          proposal: proposal_packet(ideation),
          calibration: calibration_packet
        )
        result = call_text(manifest, prompt, phase: :solve)
        checkpoint = text_checkpoint(manifest, result, phase: :solve)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        route_decline!(decision, phase: :solve) if decision&.decline? || decision&.escalate?

        body = decision_body(result)
        @ledger.write(:draft, body)
        @ledger.append_transcript('answer_recorded', chars: body.length,
                                  sha: Runes::SHA256.hex(body))
        body
      end

      def criticize!(answer)
        manifest = manifest_for(:critic)
        return nil if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        return nil if model.nil?

        auth = authorize(manifest, task: solve_task, evidence: @evidence)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :critique, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        prompt = prompt_for(
          manifest,
          instruction: CRITIC,
          task: @task_text,
          evidence: @evidence,
          perception: perception_packet,
          answer: answer
        )
        result = call_text(manifest, prompt, phase: :critique)
        checkpoint = text_checkpoint(manifest, result, phase: :critique)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        route_decline!(decision, phase: :critique) if decision&.decline? || decision&.escalate?

        body = decision_body(result)
        @ledger.write(:critique, body)
        body
      end

      # ------------------------------------------------------------------ test

      def run_test!(answer)
        violations = mechanical_checks(answer, previous_sha: nil)
        @test_violations = violations
        @test_status = violations.any?(&:error?) ? 'fail' : 'pass'
        @test_output = render_violations(violations)
        @ledger.write(:test_status, @test_status)
        @ledger.write(:test_output, @test_output)

        checkpoint = add_checkpoint(
          phase: :test, role: :verifier, manifest: manifest_for(:verifier),
          gates: control_gates(verifier: :pass),
          violations: violations, decision: nil, call: nil
        )
        stop_on_failure!(checkpoint, nil)
      end

      def run_review!(answer, critique: nil)
        scores = judge_review!(answer)
        violations = @test_violations || []
        decision, instructions = review_decision(scores, violations, critique)

        @review = {
          'schema' => 'review.v1',
          'decision' => decision,
          'support' => scores && scores['support'],
          'contradiction' => scores && scores['contradiction'],
          'sufficiency' => scores && scores['sufficiency'],
          'violations' => violations.map(&:to_h),
          'instructions' => instructions,
          'critique' => critique,
          'thresholds' => @plan.acceptance['thresholds']
        }
        @ledger.write(:review, review_markdown(@review))

        checkpoint = add_checkpoint(
          phase: :review, role: :reviewer, manifest: manifest_for(:reviewer),
          gates: control_gates,
          violations: [],
          decision: accept_decision(decision), call: nil
        )
        stop_on_failure!(checkpoint, nil)

        if decision == 'decline'
          route_decline!(decline_decision(:low_support, instructions.join('; ')), phase: :review)
        end

        @review
      end

      def judge_review!(answer, phase: :review)
        manifest = judge_manifest
        return nil if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        return nil if model.nil?

        auth = authorize(manifest, task: { 'modality' => :text, 'evidence' => 'optional' },
                                    evidence: @evidence, modality: :text)
        return nil unless auth.accept?

        questions = [
          { 'id' => 'support', 'question' => 'Is every claim supported by the evidence?',
            'type' => 'probability' },
          { 'id' => 'contradiction', 'question' => 'Does the evidence contradict a claim?',
            'type' => 'probability' },
          { 'id' => 'sufficiency', 'question' => 'Is the evidence sufficient?',
            'type' => 'probability' }
        ]
        state = {
          'task' => @task_text,
          'answer' => answer,
          'evidence' => @evidence,
          'perception' => @perception,
          'instruction' => 'Score the answer claim by claim against the evidence.'
        }
        result = call_d1(manifest, state, questions, phase: phase)
        checkpoint = d1_checkpoint(manifest, result, phase: phase, questions: questions)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        route_decline!(decision, phase: phase) if decision&.decline? || decision&.escalate?

        artifact = d1_artifact(result)
        scores = {
          'support' => numeric(verdict_value(artifact, 'support')),
          'contradiction' => numeric(verdict_value(artifact, 'contradiction')),
          'sufficiency' => numeric(verdict_value(artifact, 'sufficiency')),
          'artifact' => artifact
        }
        record_calibration(phase, artifact, checkpoint)
        scores
      end

      def review_decision(scores, violations, critique)
        thresholds = @plan.acceptance['thresholds']
        errors = violations.select(&:error?)
        support = scores && scores['support']
        contradiction = scores && scores['contradiction']
        support = 1.0 if support.nil? && errors.empty?
        support = 0.49 if support.nil? && !errors.empty?
        contradiction = 0.0 if contradiction.nil?

        if contradiction >= thresholds['decline_contradiction'].to_f ||
           support < thresholds['decline_support'].to_f
          return ['decline', ['the calibrated score is in the decline band']]
        end

        clean = errors.empty? &&
                support >= thresholds['accept_support'].to_f &&
                contradiction <= thresholds['accept_contradiction'].to_f
        return ['accept', []] if clean

        instructions = errors.empty? ? [] : errors.map { |error| "#{error.code}: #{error.message}" }
        instructions << "calibrated support #{support} is below #{thresholds['accept_support']}" if
          support < thresholds['accept_support'].to_f
        instructions << 'the critic listed unsupported or contradicted claims' unless critique.to_s.strip.empty?
        ['repair', instructions]
      end

      # ---------------------------------------------------------------- repair

      def repair!(answer, review)
        if @repair_round >= 1
          raise Stop.new(status: :repair_exhausted, final: answer, decision: nil,
                         error: 'a second repair round was refused')
        end

        manifest = manifest_for(:repairer)
        if manifest.nil?
          raise Stop.new(status: :unverified, final: answer, decision: nil,
                         error: 'the review requested a repair but no repairer is configured')
        end

        model = model_for(manifest.role, manifest.agent_id)
        if model.nil?
          raise Stop.new(status: :unverified, final: answer, decision: nil,
                         error: "no model is wired for #{manifest.agent_id}")
        end

        auth = authorize(manifest, task: solve_task, evidence: @evidence)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :repair, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        prompt = prompt_for(
          manifest,
          instruction: REPAIR,
          task: @task_text,
          evidence: @evidence,
          perception: perception_packet,
          answer: answer,
          violations: review['instructions'],
          review: review
        )
        result = call_text(manifest, prompt, phase: :repair, repair_round: 1)
        checkpoint = text_checkpoint(manifest, result, phase: :repair,
                                     previous_body: answer, repair_round: 1)
        stop_on_failure!(checkpoint, result)

        decision = result_decision(result, manifest)
        route_decline!(decision, phase: :repair) if decision&.decline? || decision&.escalate?

        body = decision_body(result)
        if Runes::SHA256.hex(body) == Runes::SHA256.hex(answer)
          raise Stop.new(status: :no_progress, final: answer, decision: nil,
                         error: 'the repair returned the same artifact as the answer')
        end

        @repair_round = 1
        @ledger.write(:draft, body)
        run_test!(body)
        if (@test_violations || []).any?(&:error?)
          raise Stop.new(status: :repair_exhausted, final: body, decision: nil,
                         error: 'the single repair round did not clear the verifier')
        end
        body
      end

      # ---------------------------------------------------------------- verify

      def verify!(answer)
        violations = mechanical_checks(answer, previous_sha: nil)
        @final_test_violations = violations
        @ledger.write(:final_test_output, render_violations(violations))

        scores = judge_review!(answer, phase: :verify)
        thresholds = @plan.acceptance['thresholds']
        support = scores && scores['support']
        contradiction = scores && scores['contradiction']
        support = 1.0 if support.nil? && violations.none?(&:error?)
        support = 0.0 if support.nil? && violations.any?(&:error?)
        contradiction = 0.0 if contradiction.nil?

        verified = violations.none?(&:error?) &&
                   support >= thresholds['accept_support'].to_f &&
                   contradiction <= thresholds['accept_contradiction'].to_f

        checkpoint = add_checkpoint(
          phase: :verify, role: :verifier, manifest: manifest_for(:verifier),
          gates: control_gates(verifier: verified ? :pass : :fail,
                               calibration: scores.nil? ? :skip : :pass),
          violations: violations, decision: nil, call: nil
        )
        stop_on_failure!(checkpoint, nil) unless verified

        @verified_answer = answer
        @ledger.write(:final, answer)
        checkpoint
      end

      def write_final_checks(answer, previous_sha:)
        violations = mechanical_checks(answer, previous_sha: previous_sha)
        @ledger.write(:final_test_output, render_violations(violations))
        violations
      end

      # -------------------------------------------------------------- finalizer

      def finalize!(answer)
        manifest = manifest_for(:finalizer)
        return answer if manifest.nil?

        model = model_for(manifest.role, manifest.agent_id)
        return answer if model.nil?

        auth = authorize(manifest, task: solve_task, evidence: @evidence)
        return answer unless auth.accept?

        prompt = prompt_for(
          manifest,
          instruction: FINALIZE,
          task: @task_text,
          evidence: @evidence,
          perception: perception_packet,
          answer: answer,
          review: @review
        )
        result = call_text(manifest, prompt, phase: :finalize)
        checkpoint = text_checkpoint(manifest, result, phase: :finalize)
        return answer unless checkpoint.passed?

        decision = result_decision(result, manifest)
        if decision&.decline? || decision&.escalate?
          @ledger.append_transcript('finalizer_declined', reason: decision.reason_code.to_s)
          return answer
        end

        body = decision_body(result)
        violations = write_final_checks(body, previous_sha: answer)
        if violations.any?(&:error?)
          @ledger.append_transcript('finalizer_rejected', reason: 'verifier')
          return answer
        end

        @answer = body
        body
      end

      # -------------------------------------------------------------- decline

      def decline!(reason, message = nil)
        decision = decline_decision(reason, message)
        raise Stop.new(status: :declined, final: nil, decision: decision,
                       error: message || decision.message)
      end

      def route_decline!(decision, phase:)
        return if decision.nil?

        if escalation_available?
          escalate!(decision.reason_code, message: decision.message, decision: decision)
        elsif decision.escalate?
          decline!(decision.reason_code, decision.message || "no local route after #{phase}")
        else
          decline!(decision.reason_code, decision.message ||
                   "the #{phase} role declined and no escalation is configured")
        end
      end

      def escalate!(reason, message: nil, decision: nil)
        manifest = manifest_for(:escalation)
        model = escalation_model

        if manifest.nil? || model.nil?
          note = "escalation_unavailable: #{message || reason}"
          @ledger.write(:decline, note)
          decline!(reason, message || note)
        end

        auth = authorize(manifest, task: { 'modality' => :text, 'evidence' => 'optional' },
                                    evidence: @evidence, modality: :text)
        unless auth.accept?
          checkpoint = add_checkpoint(
            phase: :escalate, role: manifest.role, manifest: manifest,
            gates: gated(:budget), violations: [violation(auth.reason_code, auth.message)],
            decision: auth, call: nil
          )
          stop_on_failure!(checkpoint, nil)
        end

        prompt = prompt_for(
          manifest,
          instruction: 'Answer outside local capacity. Preserve citations. ' \
                       'This is an escalation, not a local acceptance.',
          task: @task_text,
          evidence: @evidence,
          perception: perception_packet
        )
        result = call_text(manifest, prompt, phase: :escalate)
        envelope = envelope_for(result, manifest)

        if envelope.nil?
          body = result[:content].to_s
          checkpoint = external_checkpoint(manifest, result, body)
          stop_on_failure!(checkpoint, result)
          escalate_decision = Runes::Swarm::Decision.new(
            status: :escalate,
            reason_code: reason || :needs_frontier,
            next_hop: :frontier,
            message: message
          )
          raise Stop.new(status: :escalated, final: body, decision: escalate_decision,
                         error: message)
        end

        checkpoint = text_checkpoint(manifest, result, phase: :escalate)
        stop_on_failure!(checkpoint, result)

        escalate_decision = envelope.decision || decision
        if escalate_decision&.decline?
          decline!(escalate_decision.reason_code, escalate_decision.message)
        end
        body = envelope.body.to_s
        escalate_decision = Runes::Swarm::Decision.new(
          status: :escalate,
          reason_code: reason || escalate_decision&.reason_code || :needs_frontier,
          next_hop: :frontier,
          message: message || 'answered by the external escalation role'
        )
        raise Stop.new(status: :escalated, final: body.empty? ? nil : body,
                       decision: escalate_decision, error: message)
      end

      def escalation_available?
        return false if @escalation_option == false
        return false if manifest_for(:escalation).nil?

        !escalation_model.nil?
      end

      def escalation_model
        return @escalation_option if @escalation_option.respond_to?(:call) ||
                                     @escalation_option.respond_to?(:system_one)
        return nil if @escalation_option == false

        model_for(:escalation) || model_for(:escalation, manifest_for(:escalation)&.agent_id)
      end

      # ------------------------------------------------------------ checkpoints

      def d1_checkpoint(manifest, result, phase:, questions:)
        gates = blank_gates
        violations = []
        call_ok = call_ok?(result)
        gates[:call] = call_ok ? :pass : :fail
        if call_ok
          artifact = d1_artifact(result)
          envelope = envelope_for(result, manifest)
          if envelope.nil?
            gates[:envelope] = :fail
            violations << violation(:contract_invalid, 'd1 returned no envelope or typed artifact')
          else
            gates[:envelope] = :pass
            contract = contract_violations(manifest, envelope)
            apply_contract_gates!(gates, contract)
            violations.concat(contract)
            gates[:schema] = artifact_schema_ok?(artifact, manifest) ? :pass : :fail
            unless artifact_schema_ok?(artifact, manifest)
              violations << violation(:output_schema_unknown,
                                      "d1 artifact schema is #{artifact['schema'].inspect}, " \
                                      "expected #{manifest.capacity.output_schema.inspect}")
            end
            gates[:modality] = manifest.family.accepts_modality?(:text) ? :pass : :fail
            gates[:calibration] = probabilities_valid?(artifact) ? :pass : :fail
            unless probabilities_valid?(artifact)
              violations << violation(:calibration_low, 'a d1 probability is outside [0, 1]')
            end
            gates[:body] = typed_body_ok?(artifact, envelope, result) ? :pass : :fail
          end
        else
          gates[:envelope] = :skip
        end
        gates[:provenance] = :skip
        gates[:verifier] = :skip
        gates[:progress] = :pass
        gates[:budget] = @calls <= @max_calls ? :pass : :fail
        gates[:route] = :pass
        decision = envelope_for(result, manifest)&.decision
        add_checkpoint(phase: phase, role: manifest.role, manifest: manifest,
                       gates: gates, violations: violations, decision: decision,
                       call: call_summary(result))
      end

      def text_checkpoint(manifest, result, phase:, previous_body: nil, repair_round: nil)
        gates = blank_gates
        violations = []
        call_ok = call_ok?(result)
        gates[:call] = call_ok ? :pass : :fail
        if call_ok
          envelope = envelope_for(result, manifest)
          if envelope.nil? || envelope.empty?
            gates[:envelope] = :fail
            violations << violation(:contract_invalid,
                                    'the model emitted no IDENTITY/CAPACITIES/DECISION/BODY envelope')
            %i[identity capacity decision body schema].each { |gate| gates[gate] = :skip }
          else
            gates[:envelope] = :pass
            contract = contract_violations(manifest, envelope)
            apply_contract_gates!(gates, contract)
            violations.concat(contract)
            gates[:schema] = envelope.capacity&.output_schema ==
                             manifest.capacity.output_schema ? :pass : :fail
            gates[:body] = envelope_body_ok?(envelope) ? :pass : :fail
          end
          gates[:modality] = :pass
        else
          %i[envelope identity capacity decision body schema].each { |gate| gates[gate] = :skip }
        end
        gates[:provenance] = :skip
        gates[:verifier] = :skip
        gates[:calibration] = :skip
        gates[:progress] = progress_ok?(previous_body, result) ? :pass : :fail
        unless gates[:progress] == :pass
          violations << violation(:no_progress, 'the repair produced the same artifact')
        end
        gates[:budget] = @calls <= @max_calls ? :pass : :fail
        gates[:route] = :pass
        decision = envelope_for(result, manifest)&.decision
        add_checkpoint(phase: phase, role: manifest.role, manifest: manifest,
                       gates: gates, violations: violations, decision: decision,
                       call: call_summary(result), repair_round: repair_round)
      end

      def media_checkpoint(manifest, result, media:, phase:)
        gates = blank_gates
        violations = []
        call_ok = call_ok?(result)
        gates[:call] = call_ok ? :pass : :fail
        if call_ok
          artifact = result[:artifact]
          envelope = envelope_for(result, manifest)
          if envelope.nil?
            gates[:envelope] = :fail
            violations << violation(:contract_invalid, 'the media adapter returned no stamped envelope')
          else
            gates[:envelope] = :pass
            contract = contract_violations(manifest, envelope)
            apply_contract_gates!(gates, contract)
            violations.concat(contract)
          end
          gates[:schema] = artifact_schema_ok?(artifact, manifest) ? :pass : :fail
          unless gates[:schema] == :pass
            violations << violation(:output_schema_unknown,
                                    "perception schema is #{artifact && artifact['schema'].inspect}")
          end
          modality_violations = manifest.family.accepts_modality?(media[:modality]) ? [] :
            [violation(:modality_mismatch,
                       "#{manifest.base_model} cannot consume #{media[:modality]}")]
          artifact_guard = Runes::Swarm::ContractGuard.new(manifest: manifest)
          artifact_violations = artifact_guard.check_artifact(artifact)
          artifact_violations = artifact_violations.select { |item| item.code.to_s == 'modality_mismatch' }
          modality_violations += artifact_violations
          gates[:modality] = modality_violations.empty? ? :pass : :fail
          violations.concat(modality_violations)

          provenance = provenance_violations(artifact, media)
          gates[:provenance] = provenance.empty? ? :pass : :fail
          violations.concat(provenance)
        else
          %i[envelope identity capacity decision body schema modality provenance].each do |gate|
            gates[gate] = :skip
          end
        end
        gates[:verifier] = :skip
        gates[:calibration] = :skip
        gates[:progress] = :pass
        gates[:budget] = @calls <= @max_calls ? :pass : :fail
        gates[:route] = :pass
        decision = envelope_for(result, manifest)&.decision
        add_checkpoint(phase: phase, role: manifest.role, manifest: manifest,
                       gates: gates, violations: violations, decision: decision,
                       call: call_summary(result))
      end

      def external_checkpoint(manifest, result, body)
        gates = control_gates(route: :pass)
        gates[:call] = call_ok?(result) ? :pass : :fail
        gates[:body] = body.to_s.strip.empty? ? :fail : :pass
        gates[:schema] = :skip
        gates[:envelope] = :skip
        gates[:identity] = :skip
        gates[:capacity] = :skip
        gates[:decision] = :skip
        add_checkpoint(phase: :escalate, role: manifest.role, manifest: manifest,
                       gates: gates,
                       violations: body.to_s.strip.empty? ?
                         [violation(:artifact_missing, 'the escalation returned no body')] : [],
                       decision: nil, call: call_summary(result))
      end

      def apply_contract_gates!(gates, contract)
        mapping = {
          'contract_missing' => :envelope,
          'identity_missing' => :identity,
          'identity_mismatch' => :identity,
          'capacity_missing' => :capacity,
          'capacity_conflict' => :capacity,
          'capacity_overreach' => :capacity,
          'decision_missing' => :decision,
          'decision_invalid' => :decision,
          'body_missing' => :body,
          'body_forbidden' => :body,
          'output_schema_unknown' => :schema,
          'modality_mismatch' => :modality,
          'perception_shape' => :provenance,
          'provenance_missing' => :provenance,
          'forbidden_action' => :verifier,
          'calibration_low' => :calibration
        }
        affected = contract.map { |item| mapping[item.code] }.compact.uniq
        %i[identity capacity decision body schema modality provenance].each do |gate|
          gates[gate] = :pass
        end
        affected.each { |gate| gates[gate] = :fail }
        gates[:envelope] = :pass unless gates[:envelope] == :fail
      end

      def control_gates(overrides = {})
        gates = blank_gates
        %i[envelope identity capacity decision body schema verifier progress
           budget route].each { |gate| gates[gate] = :pass }
        overrides.each { |gate, status| gates[gate.to_sym] = status }
        gates
      end

      def gated(failed_gate)
        gates = blank_gates
        gates[failed_gate] = :fail
        gates
      end

      def blank_gates
        Runes::Swarm::Checkpoint::GATES.each_with_object({}) { |gate, out| out[gate] = :skip }
      end

      def add_checkpoint(phase:, role:, manifest:, gates:, violations:, decision:,
                         call:, repair_round: nil)
        @step_count += 1
        checkpoint = Runes::Swarm::Checkpoint.new(
          step: @step_count,
          role: role,
          agent_id: manifest&.agent_id,
          gates: gates,
          violations: violations
        )
        @checkpoints << checkpoint
        @violations.concat(Array(violations))
        @used_manifests << manifest unless manifest.nil? || @used_manifests.include?(manifest)

        @route << {
          'phase' => phase.to_s,
          'role' => role.to_s,
          'agent_id' => checkpoint.agent_id,
          'decision' => decision&.to_h,
          'status' => checkpoint.passed? ? 'ok' : 'failed',
          'checkpoint' => checkpoint.to_h,
          'call' => call,
          'repair_round' => repair_round
        }
        @ledger.append_transcript(
          'checkpoint',
          phase: phase.to_s,
          role: role.to_s,
          agent_id: checkpoint.agent_id,
          passed: checkpoint.passed?,
          failed_gates: checkpoint.failed_gates.map(&:to_s)
        )
        checkpoint
      end

      def stop_on_failure!(checkpoint, result)
        return checkpoint if checkpoint.passed?

        status = failure_status(checkpoint, result)
        message = checkpoint.violations.map(&:message).first ||
                  "checkpoint failed at #{checkpoint.failed_gates.map(&:to_s).join(', ')}"
        decision = if status == :unverified
                     decline_decision(:contract_invalid, message)
                   elsif status == :declined
                     decline_decision(:budget_exhausted, message)
                   end
        raise Stop.new(status: status, final: nil, decision: decision, error: message)
      end

      def failure_status(checkpoint, result)
        failed = checkpoint.failed_gates
        return :declined if failed.include?(:budget)
        return :declined if failed.include?(:route)
        return :no_progress if failed.include?(:progress)
        return :unverified unless failed.include?(:call)

        status = result.nil? ? nil : result[:status].to_s
        return :infra if status == 'infra'
        return :truncated if status == 'truncated' ||
                             (result && result[:finish_reason].to_s == 'length')
        return :empty_stop if status == 'empty_stop' || (result && result[:ok] && result[:content].to_s.strip.empty?)

        :error
      end

      # ---------------------------------------------------------------- calls

      def call_text(manifest, prompt, phase:, repair_round: nil)
        budget!(phase: phase)
        model = model_for(manifest.role, manifest.agent_id)
        return { ok: false, status: :infra, error: 'no model' } if model.nil?

        @calls += 1
        started = @clock.call
        result = begin
          if keyword_call?(model, :call)
            model.call(prompt, role: manifest.role.to_s,
                       max_tokens: manifest.capacity.max_output_tokens)
          else
            model.call(prompt)
          end
        rescue StandardError => e
          { ok: false, status: :error, error: "#{e.class}: #{e.message}" }
        end
        normalized = normalize_result(result)
        # A text model echoes the contract as prose. Parse it once here so the
        # later decision/body helpers never forward the envelope itself.
        normalized[:envelope] ||= envelope_for(normalized, manifest)
        normalized[:decision] ||= normalized[:envelope]&.decision if normalized[:envelope]
        elapsed = normalized[:elapsed_s] || (@clock.call - started)
        record_call(manifest, prompt, normalized, elapsed, phase: phase,
                    repair_round: repair_round)
        normalized.merge(elapsed_s: elapsed)
      end

      def call_d1(manifest, state, questions, media: nil, phase:)
        budget!(phase: phase)
        model = model_for(manifest.role, manifest.agent_id)
        return { ok: false, status: :infra, error: 'no model' } if model.nil?

        @calls += 1
        started = @clock.call
        prompt = state_text(state, questions)
        result = begin
          if model.respond_to?(:system_one)
            if keyword_call?(model, :system_one, :media)
              model.system_one(state, questions, media: media, role: manifest.role.to_s,
                               manifest: manifest)
            else
              model.system_one(state, questions)
            end
          elsif keyword_call?(model, :call)
            model.call(prompt, role: manifest.role.to_s)
          else
            model.call(prompt)
          end
        rescue StandardError => e
          { ok: false, status: :error, error: "#{e.class}: #{e.message}" }
        end
        normalized = normalize_result(result)
        elapsed = normalized[:elapsed_s] || (@clock.call - started)
        record_call(manifest, prompt, normalized, elapsed, phase: phase)
        normalized.merge(elapsed_s: elapsed)
      end

      def call_media(manifest, media, phase:)
        budget!(phase: phase)
        model = model_for(manifest.role, manifest.agent_id)
        return { ok: false, status: :infra, error: 'no model' } if model.nil?

        @calls += 1
        started = @clock.call
        prompt = "Perceive #{media[:path]} (#{media[:modality]}) for #{@task_text}"
        result = begin
          if keyword_call?(model, :call, :manifest)
            model.call(media[:path], role: manifest.role.to_s, manifest: manifest)
          elsif keyword_call?(model, :call, :media)
            model.call(media: media[:path], role: manifest.role.to_s)
          else
            model.call(media[:path])
          end
        rescue StandardError => e
          { ok: false, status: :error, error: "#{e.class}: #{e.message}" }
        end
        normalized = normalize_result(result)
        elapsed = normalized[:elapsed_s] || (@clock.call - started)
        record_call(manifest, prompt, normalized, elapsed, phase: phase)
        normalized.merge(elapsed_s: elapsed)
      end

      def record_call(manifest, prompt, result, elapsed, phase:, repair_round: nil)
        decision = result[:decision]
        decision = envelope_for(result, manifest)&.decision if decision.nil?
        @receipt&.add_call(
          role: manifest.role.to_s,
          prompt: prompt.to_s,
          content: result[:content].to_s,
          elapsed_s: elapsed,
          usage: result[:usage],
          finish_reason: result[:finish_reason],
          status: result[:status],
          error: result[:error],
          model: manifest.base_model
        )
        @receipt&.add_role_receipt(
          role: manifest.role.to_s,
          agent_id: manifest.agent_id,
          version: manifest.version,
          adapter_sha256: manifest.adapter_sha256,
          decision: decision&.to_h,
          status: result[:status],
          prompt: prompt.to_s,
          completion: result[:content].to_s,
          elapsed_s: elapsed,
          error: result[:error],
          model_family: manifest.base_model,
          modalities: manifest.family.modalities.map(&:to_s),
          calibration: calibration_packet,
          repair_round: repair_round
        )
        @ledger.append_transcript(
          'call_finished',
          phase: phase.to_s,
          role: manifest.role.to_s,
          agent_id: manifest.agent_id,
          status: result[:status].to_s,
          elapsed_s: elapsed.round(3),
          finish_reason: result[:finish_reason],
          error: result[:error]
        )
      end

      def normalize_result(result)
        if result.is_a?(String)
          return { ok: true, content: result, usage: nil, finish_reason: nil,
                   status: :ok, error: nil, elapsed_s: nil }
        end
        unless result.is_a?(Hash)
          return { ok: false, content: nil, usage: nil, finish_reason: nil,
                   status: :error, error: "model returned #{result.class}, not a Hash" }
        end

        hash = result.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
        status = hash[:status] || (hash[:ok] == false ? :error : :ok)
        content = hash[:content]
        content = hash[:artifact].to_s if content.nil? && hash[:artifact].is_a?(String)
        {
          ok: hash[:ok] != false,
          content: content,
          usage: hash[:usage],
          finish_reason: hash[:finish_reason],
          status: status.to_s.to_sym,
          error: hash[:error],
          artifact: hash[:artifact],
          answers: hash[:answers],
          decision: hash[:decision],
          envelope: hash[:envelope],
          family: hash[:family],
          modalities: hash[:modalities],
          elapsed_s: hash[:elapsed_s]
        }
      end

      def call_ok?(result)
        return false if result.nil?
        status = result[:status].to_s.to_sym
        # A typed decline/escalation is a successful transport call; the
        # decision gate is what routes it.
        return true if %i[declined escalate].include?(status) && !result[:decision].nil?
        return false if result[:ok] == false
        return false if %i[infra error empty_stop truncated].include?(status)
        return false if result[:content].to_s.strip.empty? && result[:artifact].nil?

        true
      end

      def call_summary(result)
        return nil if result.nil?

        {
          'n' => @calls,
          'status' => result[:status].to_s,
          'finish_reason' => result[:finish_reason],
          'error' => result[:error]
        }
      end

      def envelope_for(result, manifest)
        return nil if result.nil?

        envelope = result[:envelope]
        return envelope if envelope.is_a?(Runes::Swarm::Envelope)

        content = result[:content].to_s
        # Stamp mode: identity and capacity come from the manifest, never from
        # the model. Envelope.stamp_text keeps a complete echo (so the guard
        # can still flag a mismatch) and stamps everything else.
        return Runes::Swarm::Envelope.stamp_text(content, manifest: manifest) if manifest

        artifact = result[:artifact]
        return nil if artifact.nil? || manifest.nil?

        decision = result[:decision]
        if decision.nil?
          body = artifact.is_a?(Hash) ? (artifact['content'] || artifact['body']).to_s : artifact.to_s
          body = 'typed artifact' if body.strip.empty?
          decision = Runes::Swarm::Decision.new(status: :accept, reason_code: :ok, body: body)
        end
        Runes::Swarm::Envelope.stamp(manifest: manifest, decision: decision,
                                     body: decision.body.to_s)
      end

      def result_decision(result, manifest)
        decision = result[:decision]
        return decision if decision.is_a?(Runes::Swarm::Decision)

        envelope_for(result, manifest)&.decision
      end

      # (stamp logic lives in Envelope.stamp_text, shared with the runner's
      # solo path)

      def decision_body(result)
        decision = result[:decision]
        return decision.body if decision.is_a?(Runes::Swarm::Decision)

        envelope = result[:envelope]
        return envelope.body if envelope.is_a?(Runes::Swarm::Envelope)

        result[:content].to_s
      end

      def contract_violations(manifest, envelope)
        Runes::Swarm::ContractGuard.new(manifest: manifest).check_envelope(envelope)
      rescue StandardError => e
        [violation(:contract_invalid, "contract guard failed: #{e.message}")]
      end

      def envelope_body_ok?(envelope)
        decision = envelope.decision
        return false if decision.nil?
        return !decision.body.strip.empty? if decision.accept?

        decision.body.strip.empty?
      end

      def progress_ok?(previous_body, result)
        return true if previous_body.nil?

        Runes::SHA256.hex(decision_body(result)) != Runes::SHA256.hex(previous_body)
      end

      def typed_body_ok?(artifact, envelope, result)
        decision = envelope&.decision
        return !artifact.nil? if decision.nil?

        return !decision.body.strip.empty? if decision.accept?

        decision.body.strip.empty?
      end

      def artifact_schema_ok?(artifact, manifest)
        return false unless artifact.is_a?(Hash)

        schema = artifact['schema'] || artifact[:schema]
        schema.to_s == manifest.capacity.output_schema
      end

      def probabilities_valid?(artifact)
        answers = Array(artifact.is_a?(Hash) ? (artifact['answers'] || artifact[:answers]) : [])
        answers.all? do |answer|
          hit = false
          %w[probability prob p confidence score].each do |key|
            value = answer[key] || answer[key.to_sym]
            next if value.nil?

            hit = true
            number = numeric(value)
            return false if number.nil? || number.negative? || number > 1.0
          end
          hit || !answer.key?('probability') || numeric(answer['probability']).nil? ||
            (numeric(answer['probability']) >= 0.0 && numeric(answer['probability']) <= 1.0)
        end
      end

      def provenance_violations(artifact, media)
        return [violation(:provenance_missing, 'the perception artifact is missing')] unless artifact.is_a?(Hash)

        anchors = Array(artifact['anchors']).reject { |anchor| anchor.to_s.strip.empty? }
        out = []
        out << violation(:provenance_missing, 'the perception has no resolvable anchors') if anchors.empty?

        digest = artifact['source_sha256']
        out << violation(:provenance_missing, 'the perception has no source_sha256') if digest.to_s.empty?

        path = media[:path]
        if digest.to_s.match?(/\A[0-9a-f]{64}\z/) && path && File.file?(path)
          actual = Runes::SHA256.hex(File.binread(path))
          unless actual == digest.to_s
            out << violation(:provenance_missing,
                             "source_sha256 does not match #{path}")
          end
        end
        out
      end

      def verify_probabilities!(artifact, checkpoint)
        return if probabilities_valid?(artifact)

        violation = violation(:calibration_low, 'a d1 probability is outside [0, 1]')
        checkpoint_gate!(checkpoint, :calibration, violation)
      end

      def checkpoint_gate!(checkpoint, gate, violation)
        return if checkpoint.nil?

        @violations << violation
        @ledger.append_transcript('gate_override', gate: gate.to_s,
                                  code: violation.code)
        # The checkpoint is immutable; a failed probability is a hard stop.
        raise Stop.new(status: :unverified,
                       decision: decline_decision(:calibration_low, violation.message),
                       error: violation.message) if gate == :calibration
      end

      # ------------------------------------------------------------- utilities

      def authorize(manifest, task:, evidence:, modality: nil)
        evidence = perception_evidence if empty_evidence?(evidence) && !@perception.empty?
        auth_task = task.is_a?(Hash) ? task.dup : {}
        auth_task['modality'] ||= modality unless modality.nil?
        auth_task['evidence'] ||= empty_evidence? ? 'optional' : 'required' if @require_evidence
        @broker.authorize(
          manifest: manifest,
          task: auth_task,
          evidence: evidence,
          calls_used: @calls,
          elapsed_s: elapsed
        )
      end

      def budget!(phase:)
        if @calls >= @max_calls
          decline!(:budget_exhausted,
                   "the call budget is exhausted (#{@calls}/#{@max_calls}) before #{phase}")
        end
        if @max_wall_s && elapsed >= @max_wall_s
          decline!(:budget_exhausted,
                   "the wall-clock budget is exhausted (#{elapsed.round(2)}s/#{@max_wall_s}s) before #{phase}")
        end
        if @step_count >= @max_steps
          decline!(:budget_exhausted,
                   "the step budget is exhausted (#{@step_count}/#{@max_steps}) before #{phase}")
        end
      end

      def require_evidence!
        return unless @require_evidence
        return unless empty_evidence?

        decline!(:missing_evidence, 'this conductor requires evidence')
      end

      def empty_evidence?(evidence = @evidence)
        evidence.nil? || (evidence.respond_to?(:empty?) && evidence.empty?)
      end

      # Validated perception is evidence for every later text role. Without
      # this, a media case with no text evidence would be declined as
      # `missing_evidence` after the perception checkpoint had already passed.
      def perception_evidence
        @perception.map do |entry|
          artifact = entry['artifact'] || {}
          anchors = Array(artifact['anchors']).reject { |anchor| anchor.to_s.strip.empty? }
          {
            'citation' => anchors.first.to_s,
            'text' => perception_text(entry)
          }
        end
      end

      # The perception as plain readable text for judges and text roles —
      # not the raw artifact JSON.
      def perception_text(entry)
        artifact = entry.is_a?(Hash) ? (entry['artifact'] || entry[:artifact] || {}) : {}
        role = entry.is_a?(Hash) ? (entry['role'] || entry[:role]).to_s : ''
        content = artifact['content'] || artifact[:content] || ''
        anchors = Array(artifact['anchors'] || artifact[:anchors]).map(&:to_s).reject(&:empty?)
        source = artifact['source'] || artifact[:source]
        lines = []
        lines << "[#{role}] perception#{source ? " of #{File.basename(source.to_s)}" : ''}"
        lines << content.to_s.strip
        lines << "anchors: #{anchors.join(', ')}" unless anchors.empty?
        lines.join("\n")
      end

      def elapsed
        @started.nil? ? 0.0 : (@clock.call - @started)
      end

      def model_for(role, agent_id = nil)
        [agent_id, role.to_s, role].each do |key|
          next if key.nil?

          value = @models[key.to_s] || @models[key]
          return value unless value.nil?
        end
        nil
      end

      def manifest_for(role)
        all_by_role(role).first
      end

      def all_by_role(role)
        @registry.all_by_role(role)
      rescue Runes::Swarm::Registry::UnknownRole
        []
      end

      def judge_manifest
        candidates = all_by_role(:judge)
        candidates.find { |manifest| manifest.base_model == 'LiquidAI/d1-2B' } || candidates.first
      end

      def ordered_ideators
        all_by_role(:ideator).sort_by do |manifest|
          manifest.agent_id.end_with?('.direct') ? 0 : 1
        end
      end

      def prompt_for(manifest, instruction:, **fields)
        profile = @profiles[manifest.agent_id] || @profiles[manifest.role] ||
                  @profiles[manifest.role.to_s] ||
                  Runes::LLM::RoleProfile.for(manifest)
        profile.prompt(task: instruction, **fields)
      end

      def state_text(state, questions)
        Runes::Json.generate(
          'state' => state,
          'questions' => questions,
          'instruction' => state.is_a?(Hash) ? state['instruction'] : nil
        )
      end

      def keyword_call?(model, method, keyword = nil)
        return false unless model.respond_to?(method)

        parameters = model.method(method).parameters
        types = parameters.map(&:first)
        return true if types.include?(:keyrest)
        return true if keyword.nil? && types.include?(:key)

        !keyword.nil? && parameters.any? { |type, name| %i[key keyreq].include?(type) && name == keyword }
      end

      def d1_artifact(result)
        artifact = result[:artifact]
        if artifact.is_a?(Hash)
          artifact.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        elsif result[:answers].is_a?(Array)
          { 'schema' => 'verdict.v1', 'answers' => result[:answers] }
        else
          {}
        end
      end

      def d1_text(artifact)
        answers = Array(artifact['answers'])
        return artifact['body'].to_s if answers.empty? && !artifact['body'].to_s.strip.empty?

        text = answers.map do |answer|
          id = answer['id'] || answer[:id]
          value = answer.key?('value') ? answer['value'] : answer[:value]
          "#{id}=#{value}"
        end.reject(&:empty?).join('; ')
        return text unless text.empty?

        Runes::Json.generate(artifact)
      end

      def verdict_value(artifact, key)
        return nil unless artifact.is_a?(Hash)

        answers = Array(artifact['answers'])
        found = answers.find { |answer| answer['id'].to_s == key.to_s }
        return found['value'] if found.is_a?(Hash) && found.key?('value')
        return found[:value] if found.is_a?(Hash) && found.key?(:value)

        artifact[key] || artifact[key.to_s] ||
          (artifact['decision'].is_a?(Hash) ? artifact['decision'][key] : nil)
      end

      def numeric(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)

        text = value.to_s.strip
        return nil unless text.match?(/\A-?\d+(?:[.,]\d+)?\z/)

        text.tr(',', '.').to_f
      end

      def record_calibration(phase, artifact, checkpoint)
        record = {
          'phase' => phase.to_s,
          'artifact' => artifact,
          'checkpoint_step' => checkpoint&.step,
          'passed' => checkpoint&.passed?
        }
        @calibration_records << record
        @ledger.write_json(:calibration, @calibration_records)
      end

      def calibration_packet
        return nil if @calibration_records.empty?

        @calibration_records.last
      end

      def perception_packet
        return nil if @perception.empty?

        @perception.map { |entry| entry['artifact'] }.compact
      end

      def proposal_packet(ideation)
        return nil if ideation.nil?

        {
          'choice' => ideation['choice'],
          'proposals' => ideation['proposals'].map { |proposal| proposal['body'] },
          'support' => ideation['support']
        }
      end

      def solve_task
        { 'modality' => :text, 'evidence' => empty_evidence? ? 'optional' : 'required', 'required' => [] }
      end

      def budgets
        { calls: @max_calls, steps: @max_steps, wall_s: @max_wall_s || 300 }
      end

      def merge_profile(base, task)
        merged = (base || {}).dup
        (task || {}).each { |key, value| merged[key] = value unless value.nil? }
        merged
      end

      def normalize_media(value)
        entries = value.is_a?(Array) ? value : [value]
        entries.compact.map do |entry|
          hash =
            if entry.is_a?(Hash)
              entry.each_with_object({}) { |(key, item), out| out[key.to_s] = item }
            else
              { 'path' => entry.to_s }
            end
          path = hash['path'] || hash['file'] || hash['input']
          modality = hash['modality']
          {
            path: path&.to_s,
            modality: modality.nil? ? infer_modality(path) : Shape.normalize_modality(modality),
            sha256: hash['sha256'] || hash['source_sha256']
          }
        end
      end

      def media_modality
        first = @media.first
        first && first[:modality]
      end

      def media_path
        first = @media.first
        first && first[:path]
      end

      def media_summary
        @media.map { |entry| { 'path' => entry[:path], 'modality' => entry[:modality].to_s } }
      end

      def infer_modality(path)
        extension = File.extname(path.to_s).downcase
        return :audio if %w[.wav .mp3 .m4a .flac .ogg .aac .opus .aiff .aif].include?(extension)
        return :video if %w[.mp4 .mov .mkv .webm .avi .m4v].include?(extension)
        return :image if %w[.png .jpg .jpeg .gif .webp .bmp .tiff .tif .pdf].include?(extension)

        :image
      end

      def needs_reason(role)
        case role
        when :vision then :needs_vision
        when :audio then :needs_audio
        when :omni then :needs_omni
        else :needs_perception
        end
      end

      def task_text(task)
        return '' if task.nil?
        return task.to_s unless task.is_a?(Hash)

        hash = task.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        text = hash['question'] || hash['task'] || hash['prompt'] || hash['text']
        text.nil? ? Runes::Json.generate(task) : text.to_s
      end

      def accept_decision(body)
        Runes::Swarm::Decision.new(status: :accept, reason_code: :ok, body: body.to_s)
      end

      def decline_decision(reason, message = nil)
        reason = reason.to_s.to_sym
        reason = :no_route unless Runes::Swarm::Decision::REASONS.include?(reason)
        Runes::Swarm::Decision.new(status: :decline, reason_code: reason,
                                   message: message || reason.to_s)
      end

      def violation(code, message)
        Violation.new(code: code, message: message, severity: :error)
      end

      def mechanical_checks(text, previous_sha:)
        guards = @guards || Guards.new(
          task: @task_text,
          evidence: @evidence,
          checks: @explicit_checks || (@plan && @plan.acceptance['checks']) || {}
        )
        receipt = {
          status: 'ok',
          finish_reason: nil,
          artifact_sha: Runes::SHA256.hex(text.to_s),
          previous_sha: previous_sha
        }
        found = guards.check(text, receipt: receipt)
        if @verifier && !@verifier.equal?(guards)
          extra = @verifier.call(text, evidence: @evidence, task: @task_text, receipt: receipt)
          found += Array(extra)
        end
        found.uniq { |item| [item.code, item.message] }
      end

      def render_violations(violations)
        list = Array(violations).map do |item|
          "- #{item.code}: #{item.message} [#{item.severity}]"
        end
        list.empty? ? "- none\n" : list.join("\n") + "\n"
      end

      def review_markdown(review)
        lines = ['# review.v1']
        lines << ''
        lines << "decision: #{review['decision']}"
        lines << "support: #{review['support']}"
        lines << "contradiction: #{review['contradiction']}"
        lines << "sufficiency: #{review['sufficiency']}"
        lines << ''
        lines << '## instructions'
        instructions = Array(review['instructions'])
        lines.concat(instructions.empty? ? ['- none'] : instructions.map { |item| "- #{item}" })
        lines << ''
        lines << '## violations'
        violations = Array(review['violations'])
        lines.concat(violations.empty? ? ['- none'] : violations.map { |item| "- #{item['code']}: #{item['message']}" })
        lines << ''
        lines.join("\n")
      end

      def model_name
        @models['answerer']&.model_name || @models['answerer']&.class&.name || 'scripted-team'
      end

      def normalize_models(models)
        (models || {}).each_with_object({}) do |(key, value), out|
          out[key.to_s] = value
        end
      end

      # ------------------------------------------------------------------ exit

      def finish(status, final, decision: nil, error: nil)
        return @finished if @finished

        status = status.to_sym
        decision ||= accept_decision(final) if %i[ok repaired].include?(status) &&
                                                final && !final.to_s.empty?

        write_contract_artifacts(status, decision, error)
        @receipt ||= Runes::RunReceipt.new(run_id: @ledger.run_id, model: model_name)
        @receipt.finish(status: status)
        @ledger.update_manifest(
          @receipt.to_h.merge(
            'status' => status.to_s,
            'shape' => @plan&.shape&.to_s,
            'error' => error,
            'final_sha' => final.nil? ? nil : Runes::SHA256.hex(final.to_s)
          )
        )
        @ledger.append_transcript('run_finished', status: status.to_s,
                                  calls: @calls, error: error)

        @finished = Result.new(
          status: status,
          shape: @plan&.shape || @selected_shape,
          final: final,
          decision: decision,
          route: @route,
          checkpoints: @checkpoints,
          violations: @violations,
          receipt: @receipt,
          ledger: @ledger,
          error: error,
          elapsed_s: @receipt.elapsed_s,
          plan: @plan
        )
      end

      def write_contract_artifacts(status, decision, error)
        identities = {}
        capacities = {}
        @used_manifests.each do |manifest|
          identities[manifest.agent_id] = manifest.identity.to_h
          capacities[manifest.agent_id] = manifest.capacity.to_h
        end
        @ledger.write_json(:identity, identities)
        @ledger.write_json(:capacities, capacities)
        @ledger.write_json(:decision, decision&.to_h) unless decision.nil?

        if %i[declined escalated unverified error infra truncated empty_stop
              no_progress proposal_collapse repair_exhausted].include?(status)
          @ledger.write(:decline, error || status.to_s)
        end

        @ledger.write_json(:checkpoints, @checkpoints.map(&:to_h))
        @ledger.write_json(:role_receipts, @receipt&.role_receipts&.map(&:to_h) || [])
        @ledger.write_json(:triage, @triage ? {
          'artifact' => @triage[:artifact],
          'decision' => @triage[:decision]&.to_h,
          'agent_id' => @triage[:manifest]&.agent_id
        } : {})
        @ledger.write_json(:proposals, @proposals)
        @ledger.write_json(:perception, @perception)
        @ledger.write(:review, review_markdown(@review)) unless @review.nil?
        @ledger.write(:test_status, @test_status) unless @test_status.nil?
        @ledger.write(:test_output, @test_output) unless @test_output.nil?
        @ledger.write_json(:calibration, @calibration_records)
        @ledger.write(:notes, notes(status, error))
      end

      def notes(status, error)
        lines = ['# run notes']
        lines << ''
        lines << "status: #{status}"
        lines << "shape: #{@plan&.shape}"
        lines << "calls: #{@calls}"
        lines << "steps: #{@step_count}"
        lines << "repair_round: #{@repair_round}"
        lines << "error: #{error}" unless error.nil?
        lines << ''
        lines << '## route'
        @route.each do |entry|
          lines << "- #{entry['phase']}: #{entry['role']} " \
                   "(#{entry['status']})#{entry['checkpoint'] ? '' : ' UNVALIDATED'}"
        end
        lines << ''
        lines.join("\n")
      end
    end
  end
end
