# frozen_string_literal: true

require_relative '../compat'
require_relative '../json_facade'
require_relative '../sha256_facade'
require_relative 'guards'
require_relative 'receipt'
require_relative 'violation'

module Runes
  module Orchestration
    # The cumulative role loop.
    #
    # The model never gets free write access: it emits text, the harness writes
    # it to the ledger, and a Ruby verifier decides whether it is acceptable.
    # Adaptive mode calls once and repairs only on a verifier failure; forced
    # mode always spends the remaining call(s) as a control.
    class Cumulative
      DEFAULT_SOLVER = <<~TEXT
        You answer a question using only the supplied evidence.
        Never add facts from general knowledge. If the evidence does not
        explicitly contain the requested value, answer "non documenté".
        If a room resolution is not "resolved", do not present the room as
        existing. End with a line "Citations: ..." containing the exact
        citations you used, or "Citations: aucune".
      TEXT

      DEFAULT_REPAIR = <<~TEXT
        The candidate answer failed these code checks:
        %{violations}

        Rewrite the answer to fix exactly those points. Use only the supplied
        evidence. Do not invent a fact. End with a line "Citations: ...".
      TEXT

      DEFAULT_CRITIC = <<~TEXT
        You are a document critic. Do not rewrite the answer. Compare the
        candidate with the evidence and reply with exactly these sections:
        ### SOUTENU
        - <claim> — <citation>
        ### NON_SOUTENU
        - <claim> — <why it is not in the evidence>
        ### CORRECTIONS
        - <room to fix, value to remove, or abstention to state>
        Add no facts. If everything is supported, write "- aucune" under
        NON_SOUTENU.
      TEXT

      DEFAULT_FINALIZER = <<~TEXT
        Rewrite the answer in at most three sentences, applying the
        corrections. Use only the supplied evidence. If the corrections ask
        for an abstention, answer "non documenté". End with a line
        "Citations: ..." containing the exact citations you used.
      TEXT

      class Result
        attr_reader :status, :final, :violations, :receipt, :ledger, :error, :elapsed_s

        def initialize(status:, final:, violations:, receipt:, ledger:, error: nil, elapsed_s: nil)
          @status = status.to_sym
          @final = final
          @violations = violations || []
          @receipt = receipt
          @ledger = ledger
          @error = error
          @elapsed_s = elapsed_s
        end

        def ok?
          %i[ok repaired].include?(status)
        end

        def calls
          receipt ? receipt.calls : []
        end

        def to_h
          {
            'status' => status.to_s,
            'final' => final,
            'violations' => violations.map(&:to_h),
            'receipt' => receipt&.to_h,
            'error' => error,
            'elapsed_s' => elapsed_s
          }
        end
      end

      def initialize(llm:, ledger:, guards: nil, verifier: nil, max_calls: 1,
                     mode: :adaptive, critic_llm: nil, max_wall_s: nil,
                     prompts: {}, model_name: nil, sampler: {}, arm: nil,
                     case_id: nil, max_tokens: nil, solver_max_tokens: nil,
                     repair_max_tokens: nil, critic_max_tokens: nil,
                     finalizer_max_tokens: nil, clock: nil)
        @llm = llm
        @ledger = ledger
        @guards = guards
        @verifier = verifier
        @max_calls = Integer(max_calls)
        raise ArgumentError, 'max_calls must be 1, 2 or 3' unless (1..3).cover?(@max_calls)

        @mode = mode.to_sym
        raise ArgumentError, 'mode must be :adaptive or :forced' unless %i[adaptive forced].include?(@mode)

        @critic_llm = critic_llm
        @max_wall_s = max_wall_s.nil? ? nil : max_wall_s.to_f
        @prompts = prompts || {}
        @model_name = model_name
        @sampler = sampler || {}
        @arm = arm
        @case_id = case_id
        @max_tokens = max_tokens
        @solver_max_tokens = solver_max_tokens
        @repair_max_tokens = repair_max_tokens
        @critic_max_tokens = critic_max_tokens
        @finalizer_max_tokens = finalizer_max_tokens
        @clock = clock || -> { Runes::Compat.monotonic }
        @calls = 0
        @started = nil
      end

      def run(task:, evidence:)
        @task = task.to_s
        @evidence = evidence
        @ledger.write(:task, @task)
        @ledger.write_json(:evidence, @evidence)
        @started = @clock.call
        @receipt = Runes::RunReceipt.new(
          run_id: @ledger.run_id,
          model: @model_name || model_name_of(@llm),
          sampler: @sampler,
          arm: @arm,
          case_id: @case_id
        )
        @ledger.update_manifest(
          'run_id' => @ledger.run_id,
          'model' => @receipt.model,
          'sampler' => @sampler,
          'arm' => @arm,
          'case_id' => @case_id,
          'task_sha' => Runes::SHA256.hex(@task),
          'evidence_sha' => Runes::SHA256.hex(Runes::Json.generate(@evidence))
        )
        @ledger.append_transcript('run_started', model: @receipt.model, arm: @arm, case_id: @case_id)
        execute
      rescue StandardError => e
        finish(:error, nil, [], error: "#{e.class}: #{e.message}")
      end

      private

      def execute
        prompt = build_solver_prompt
        call = call_model(@llm, prompt, role: 'solver', max_tokens: max_tokens_for(:solver))
        return finish(:infra, nil, [], error: 'no call budget available') if call.nil?

        if !call[:ok]
          return second_call('', [error_violation('artifact_missing', 'the model produced no artifact')],
                             forced_clean: false) if call[:status].to_s == 'empty_stop' && @max_calls > 1

          return finish(call_status(call), nil, [], error: call[:error])
        end

        draft = call[:content].to_s
        @ledger.write(:draft, draft)
        if draft.strip.empty?
          return second_call('', [error_violation('artifact_missing', 'the draft is empty')],
                             forced_clean: false) if @max_calls > 1

          return finish(:empty_stop, draft, [], error: 'the model returned an empty draft')
        end

        if call[:finish_reason].to_s == 'length'
          @ledger.preserve_cutoff!(:draft, draft)
          return second_call(draft, [error_violation('truncated', 'the draft hit the output cap')],
                             forced_clean: false) if @max_calls > 1

          return finish(:truncated, draft, [error_violation('truncated', 'the draft hit the output cap')])
        end

        violations = verify(draft, call)
        if errors?(violations).empty?
          return finish(:ok, draft, violations) if @max_calls == 1 || @mode == :adaptive

          return second_call(draft, violations, forced_clean: true) if @max_calls == 2

          return critic_then_finalize(draft, violations, forced_clean: true)
        end

        return finish(:unverified, draft, violations) if @max_calls == 1

        @max_calls == 2 ? second_call(draft, violations) : critic_then_finalize(draft, violations)
      end

      def second_call(draft, violations, forced_clean: false)
        return finish(:unverified, draft, violations, error: 'no call budget available') unless budget_available?

        if forced_clean
          prompt = build_finalizer_prompt(draft, nil)
        else
          prompt = build_repair_prompt(draft, violations)
        end
        call = call_model(@llm, prompt, role: forced_clean ? 'finalizer' : 'repair',
                          max_tokens: max_tokens_for(forced_clean ? :finalizer : :repair))
        return finish(:infra, draft, violations, error: 'no call budget available') if call.nil?
        return finish(call_status(call), draft, violations, error: call[:error]) unless call[:ok]

        final = call[:content].to_s
        @ledger.write(:final, final)
        checked = verify(final, call, previous_sha: Runes::SHA256.hex(draft))
        status = status_after_check(checked, call, initial_errors: !forced_clean)
        finish(status, final, checked, error: status == :no_progress ? 'no progress after repair' : nil)
      end

      def critic_then_finalize(draft, violations, forced_clean: false)
        return finish(:unverified, draft, violations, error: 'no call budget available') unless budget_available?

        critic = @critic_llm || @llm
        critic_prompt = build_critic_prompt(draft, violations)
        critic_call = call_model(critic, critic_prompt, role: 'critic',
                                 max_tokens: max_tokens_for(:critic))
        return finish(:infra, draft, violations, error: 'no call budget available') if critic_call.nil?
        unless critic_call[:ok]
          return finish(call_status(critic_call), draft, violations, error: critic_call[:error])
        end

        critique = critic_call[:content].to_s
        @ledger.write(:critique, critique)
        return finish(:unverified, draft, violations, error: 'no call budget available') unless budget_available?

        final_prompt = build_finalizer_prompt(draft, critique)
        final_call = call_model(@llm, final_prompt, role: 'finalizer',
                                max_tokens: max_tokens_for(:finalizer))
        return finish(:infra, draft, violations, error: 'no call budget available') if final_call.nil?
        return finish(call_status(final_call), draft, violations, error: final_call[:error]) unless final_call[:ok]

        final = final_call[:content].to_s
        @ledger.write(:final, final)
        checked = verify(final, final_call, previous_sha: Runes::SHA256.hex(draft))
        status = status_after_check(checked, final_call, initial_errors: !forced_clean)
        finish(status, final, checked, error: status == :no_progress ? 'no progress after finalizer' : nil)
      end

      def call_model(model, prompt, role:, max_tokens: nil)
        return nil unless budget_available?

        @calls += 1
        started = @clock.call
        result = model.call(prompt, role: role, max_tokens: max_tokens)
        elapsed = result.is_a?(Hash) && result[:elapsed_s] ? result[:elapsed_s] : (@clock.call - started)
        normalized = normalize_result(result)
        @receipt.add_call(
          role: role,
          prompt: prompt,
          content: normalized[:content],
          elapsed_s: elapsed,
          usage: normalized[:usage],
          finish_reason: normalized[:finish_reason],
          status: normalized[:status],
          error: normalized[:error],
          model: model_name_of(model)
        )
        @ledger.append_transcript(
          'call_finished',
          role: role,
          status: normalized[:status].to_s,
          elapsed_s: elapsed.round(3),
          finish_reason: normalized[:finish_reason],
          error: normalized[:error]
        )
        normalized.merge(elapsed_s: elapsed)
      rescue StandardError => e
        @receipt.add_call(role: role, prompt: prompt, status: :error, error: "#{e.class}: #{e.message}",
                          model: model_name_of(model))
        { ok: false, status: :error, error: "#{e.class}: #{e.message}", content: nil }
      end

      def normalize_result(result)
        if result.is_a?(String)
          return { ok: true, content: result, usage: nil, finish_reason: nil, status: :ok, error: nil }
        end
        unless result.is_a?(Hash)
          return { ok: false, content: nil, usage: nil, finish_reason: nil, status: :error,
                   error: "model returned #{result.class}, not a Hash" }
        end

        status = result[:status] || (result[:ok] ? :ok : :error)
        {
          ok: result[:ok] != false,
          content: result[:content],
          usage: result[:usage],
          finish_reason: result[:finish_reason],
          status: status,
          error: result[:error]
        }
      end

      def verify(text, call, previous_sha: nil)
        receipt = {
          status: call[:status],
          finish_reason: call[:finish_reason],
          artifact_sha: Runes::SHA256.hex(text),
          previous_sha: previous_sha
        }
        guards = @guards || Guards.new(task: @task, evidence: @evidence)
        found = guards.check(text, receipt: receipt)
        if @verifier && !@verifier.equal?(guards)
          extra = @verifier.call(text, evidence: @evidence, task: @task, receipt: receipt)
          found += Array(extra)
        end
        found.uniq { |violation| [violation.code, violation.message] }
      end

      def status_after_check(violations, call, initial_errors:)
        errors = errors?(violations)
        return :no_progress if errors.any? { |v| v.code == 'no_progress' }
        return :truncated if call[:finish_reason].to_s == 'length' || call[:status].to_s == 'truncated'
        return :unverified if errors.any?

        initial_errors ? :repaired : :ok
      end

      def errors?(violations)
        violations.select { |violation| violation.error? }
      end

      def finish(status, final, violations, error: nil)
        @receipt ||= Runes::RunReceipt.new(
          run_id: @ledger.run_id,
          model: @model_name,
          sampler: @sampler,
          arm: @arm,
          case_id: @case_id
        )
        @ledger.write(:final, final) unless final.nil?
        @ledger.write_json(:violations, Array(violations).map(&:to_h))
        @receipt.finish(status: status)
        @ledger.update_manifest(@receipt.to_h.merge('error' => error))
        @ledger.append_transcript('run_finished', status: status.to_s, calls: @calls, error: error)
        Result.new(
          status: status,
          final: final,
          violations: Array(violations),
          receipt: @receipt,
          ledger: @ledger,
          error: error,
          elapsed_s: @receipt.elapsed_s
        )
      end

      def call_status(call)
        status = call[:status].to_s
        return :infra if status == 'infra'
        return :truncated if status == 'truncated' || call[:finish_reason].to_s == 'length'
        return :empty_stop if status == 'empty_stop'

        :error
      end

      def budget_available?
        return false if @calls >= @max_calls

        @max_wall_s.nil? || (@clock.call - @started) < @max_wall_s
      end

      def elapsed
        @started.nil? ? 0.0 : @clock.call - @started
      end

      def max_tokens_for(role)
        specific = instance_variable_get("@#{role}_max_tokens")
        specific || @max_tokens
      end

      def build_solver_prompt
        template = @prompts[:solver] || DEFAULT_SOLVER
        return template.call(@task, @evidence) if template.respond_to?(:call)

        "#{template}\n\n#{context}"
      end

      def build_repair_prompt(draft, violations)
        template = (@prompts[:repair] || DEFAULT_REPAIR).to_s
        text = template.gsub('%{violations}', violations_text(violations))
        "#{text}\n\n#{context}\n\nCANDIDATE:\n#{draft}"
      end

      def build_critic_prompt(draft, violations)
        template = (@prompts[:critic] || DEFAULT_CRITIC).to_s
        "#{template}\n\n#{context}\n\nCANDIDATE:\n#{draft}\n\nCODE CHECKS FAILED:\n#{violations_text(violations)}"
      end

      def build_finalizer_prompt(draft, critique)
        template = (@prompts[:finalizer] || DEFAULT_FINALIZER).to_s
        prompt = "#{template}\n\n#{context}\n\nCANDIDATE:\n#{draft}"
        prompt += "\n\nCRITIQUE:\n#{critique}" unless critique.nil? || critique.empty?
        prompt
      end

      def context
        "TASK:\n#{@task}\n\nEVIDENCE:\n#{Runes::Json.generate(@evidence)}"
      end

      def violations_text(violations)
        list = Array(violations).map { |violation| "- #{violation.code}: #{violation.message}" }
        list.empty? ? '- none' : list.join("\n")
      end

      def error_violation(code, message)
        Violation.new(code: code, message: message, severity: :error)
      end

      def model_name_of(model)
        return model.model_name if model.respond_to?(:model_name)
        return model.class.name if model.respond_to?(:class)

        'unknown'
      end
    end
  end
end
