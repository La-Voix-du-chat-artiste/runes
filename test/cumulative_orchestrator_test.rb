# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class CumulativeOrchestratorTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def model_name
      "scripted"
    end

    def call(prompt, role: nil, max_tokens: nil)
      @calls << { prompt: prompt, role: role, max_tokens: max_tokens }
      response = @responses.shift
      response = response.call(prompt, role) if response.respond_to?(:call)
      response = { ok: true, content: response.to_s, status: :ok } if response.is_a?(String)
      response || { ok: false, status: :error, error: "no scripted response" }
    end
  end

  def setup
    @root = Dir.mktmpdir("runes-cumulative-")
    @ledger = Runes::WorkLedger.new(root: @root, run_id: "g1-2x-s0")
    @guards = Runes::Orchestration::Guards.new(task: "question", evidence: [])
  end

  def teardown
    FileUtils.remove_entry(@root, true) if @root && Dir.exist?(@root)
  end

  def verifier
    lambda do |artifact, **|
      if artifact.include?("BAD")
        [Runes::Orchestration::Violation.new(code: "bad_claim", message: "contains BAD")]
      else
        []
      end
    end
  end

  def build(model, **options)
    Runes::Orchestration::Cumulative.new(
      llm: model,
      ledger: @ledger,
      guards: @guards,
      verifier: verifier,
      model_name: "scripted",
      **options
    )
  end

  def test_one_x_accepts_a_clean_draft_with_one_call
    model = ScriptedModel.new(["good answer"])
    result = build(model, max_calls: 1).run(task: "question", evidence: [])

    assert_equal :ok, result.status
    assert_equal "good answer", result.final
    assert_equal 1, model.calls.size
    assert_equal %w[solver], model.calls.map { |call| call[:role] }
  end

  def test_one_x_returns_unverified_on_a_failed_check
    model = ScriptedModel.new(["BAD answer"])
    result = build(model, max_calls: 1).run(task: "question", evidence: [])

    assert_equal :unverified, result.status
    assert_equal 1, model.calls.size
    assert_includes result.violations.map(&:code), "bad_claim"
  end

  def test_two_x_adaptive_repairs_only_after_failure
    model = ScriptedModel.new(["BAD answer", "good answer"])
    result = build(model, max_calls: 2, mode: :adaptive).run(task: "question", evidence: [])

    assert_equal :repaired, result.status
    assert_equal %w[solver repair], model.calls.map { |call| call[:role] }
    assert_equal "good answer", result.final
  end

  def test_two_x_adaptive_does_not_spend_a_second_call_on_a_clean_draft
    model = ScriptedModel.new(["good answer"])
    result = build(model, max_calls: 2, mode: :adaptive).run(task: "question", evidence: [])

    assert_equal :ok, result.status
    assert_equal 1, model.calls.size
  end

  def test_two_x_forced_always_spends_the_second_call
    model = ScriptedModel.new(["good draft", "good final"])
    result = build(model, max_calls: 2, mode: :forced).run(task: "question", evidence: [])

    assert_equal :ok, result.status
    assert_equal %w[solver finalizer], model.calls.map { |call| call[:role] }
    assert_equal "good final", result.final
  end

  def test_three_x_adaptive_uses_critic_then_finalizer_after_failure
    model = ScriptedModel.new(["BAD draft", "critique", "good final"])
    result = build(model, max_calls: 3, mode: :adaptive).run(task: "question", evidence: [])

    assert_equal :repaired, result.status
    assert_equal %w[solver critic finalizer], model.calls.map { |call| call[:role] }
    assert_equal "critique", @ledger.read(:critique)
  end

  def test_three_x_forced_always_spends_three_calls_even_when_clean
    model = ScriptedModel.new(["good draft", "critique", "good final"])
    result = build(model, max_calls: 3, mode: :forced).run(task: "question", evidence: [])

    assert_equal :ok, result.status
    assert_equal %w[solver critic finalizer], model.calls.map { |call| call[:role] }
    assert_equal 3, result.calls.size
  end

  def test_it_stops_on_an_empty_solver_response
    model = ScriptedModel.new([{ ok: true, content: "", status: :ok }])
    result = build(model, max_calls: 1).run(task: "question", evidence: [])

    assert_equal :empty_stop, result.status
    assert_equal 1, model.calls.size
  end

  def test_it_preserves_a_truncated_draft_and_reports_truncated
    model = ScriptedModel.new([{ ok: true, content: "partial", status: :ok, finish_reason: "length" }])
    result = build(model, max_calls: 1).run(task: "question", evidence: [])

    assert_equal :truncated, result.status
    assert_equal "partial", @ledger.read(:"draft.cutoff")
    assert_includes result.violations.map(&:code), "truncated"
  end

  def test_it_retries_a_truncated_draft_once_when_a_second_call_is_available
    model = ScriptedModel.new([
      { ok: true, content: "partial", status: :ok, finish_reason: "length" },
      "complete answer"
    ])
    result = build(model, max_calls: 2, mode: :adaptive).run(task: "question", evidence: [])

    assert_equal :repaired, result.status
    assert_equal %w[solver repair], model.calls.map { |call| call[:role] }
  end

  def test_it_reports_infrastructure_failure_without_retrying
    model = ScriptedModel.new([{ ok: false, status: :infra, error: "server down" }])
    result = build(model, max_calls: 3, mode: :adaptive).run(task: "question", evidence: [])

    assert_equal :infra, result.status
    assert_equal 1, model.calls.size
    assert_equal "server down", result.error
  end

  def test_it_reports_no_progress_when_repair_is_identical
    model = ScriptedModel.new(["BAD answer", "BAD answer"])
    result = build(model, max_calls: 2, mode: :adaptive).run(task: "question", evidence: [])

    assert_equal :no_progress, result.status
    assert_equal 2, model.calls.size
  end

  def test_it_uses_a_separate_critic_model
    solver = ScriptedModel.new(["BAD draft"])
    critic = ScriptedModel.new(["critique"])
    finalizer = ScriptedModel.new(["good final"])
    model = Object.new
    model.define_singleton_method(:model_name) { "router" }
    model.define_singleton_method(:call) do |prompt, role:, max_tokens: nil|
      case role
      when "solver" then solver.call(prompt, role: role, max_tokens: max_tokens)
      when "critic" then critic.call(prompt, role: role, max_tokens: max_tokens)
      else finalizer.call(prompt, role: role, max_tokens: max_tokens)
      end
    end

    result = Runes::Orchestration::Cumulative.new(
      llm: model,
      critic_llm: critic,
      ledger: @ledger,
      guards: @guards,
      verifier: verifier,
      max_calls: 3,
      mode: :adaptive
    ).run(task: "question", evidence: [])

    assert_equal :repaired, result.status
    assert_equal 1, critic.calls.size
    assert_equal 1, finalizer.calls.size
  end

  def test_the_transcript_is_never_part_of_a_prompt
    @ledger.append_transcript("secret", note: "DO NOT PROMPT")
    model = ScriptedModel.new(["good answer"])
    build(model, max_calls: 1).run(task: "question", evidence: [])

    refute_includes model.calls.first[:prompt], "DO NOT PROMPT"
  end

  def test_it_honours_the_wall_clock_budget
    model = ScriptedModel.new(["good answer"])
    clock = 0.0
    result = build(model, max_calls: 2, mode: :adaptive, max_wall_s: 0.0, clock: -> { clock }).run(
      task: "question", evidence: []
    )

    assert_equal :infra, result.status
    assert_equal 0, model.calls.size
  end
end
