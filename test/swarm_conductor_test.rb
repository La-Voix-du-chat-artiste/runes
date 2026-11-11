# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

# Phase 5 acceptance for the supervised team conductor.
#
# Every model is scripted: these tests never load an LFM3 checkpoint, touch
# the network or need a GPU. The point is the control plane: one micro-task
# per call, a 14-gate checkpoint for every hop, first-class decline/escalate
# routing, exactly one repair, and a Ruby verifier that owns acceptance.
class SwarmConductorTest < Minitest::Test
  AGENTS = File.expand_path("../config/agents", __dir__)
  EVIDENCE = [
    { "citation" => "page:1", "text" => "Le total de la facture est 128,40." }
  ].freeze
  TASK = "Quel est le total de la facture ?"

  # --------------------------------------------------------------- fakes

  class ScriptedText
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def call(prompt, role: nil, max_tokens: nil)
      @calls << { prompt: prompt, role: role, max_tokens: max_tokens }
      result = @handler.call(prompt, role)
      case result
      when Hash
        result
      when String
        { ok: true, content: result, usage: nil, finish_reason: nil,
          status: :ok, error: nil }
      else
        { ok: false, status: :error,
          error: "scripted text returned #{result.class}" }
      end
    end
  end

  class ScriptedD1
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def system_one(state, questions, media: nil, role: nil, manifest: nil)
      @calls << { state: state, questions: questions, media: media,
                  role: role, manifest: manifest }
      @handler.call(state, questions, manifest)
    end

    def call(state, questions = [], **kwargs)
      system_one(state, questions, **kwargs)
    end
  end

  class ScriptedMedia
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def call(input = nil, media: nil, role: nil, manifest: nil)
      @calls << { input: input, media: media, role: role, manifest: manifest }
      @handler.call(input, manifest)
    end
  end

  # --------------------------------------------------------------- setup

  def setup
    @root = Dir.mktmpdir("runes-conductor-")
    @ledger = Runes::WorkLedger.new(root: @root, run_id: "team-test")
    @registry = Runes::Swarm::Registry.new(Runes::Swarm::Manifest.load_all(AGENTS))
    @models = {}
  end

  def teardown
    FileUtils.remove_entry(@root, true) if @root && Dir.exist?(@root)
  end

  def models
    @models
  end

  def fetch_manifest(agent_id)
    @registry.fetch!(agent_id)
  end

  def registry_without(*roles)
    manifests = Runes::Swarm::Manifest.load_all(AGENTS)
                                  .reject { |manifest| roles.include?(manifest.role) }
    Runes::Swarm::Registry.new(manifests)
  end

  def build_conductor(registry: nil, **options)
    Runes::Orchestration::Conductor.new(
      registry: registry || @registry,
      ledger: @ledger,
      models: models,
      **options
    )
  end

  # ------------------------------------------------------------ fixtures

  # A tolerant echo of the assigned identity/capacity blocks, exactly the
  # contract `Envelope.parse` is written to accept.
  def envelope(target, body:, status: "accept", reason: "ok", next_hop: nil,
               message: "ok", agent_id: nil)
    identity = target.identity.to_h
    capacity = target.capacity.to_h
    <<~TEXT
      ### IDENTITY
      agent_id: #{agent_id || identity['agent_id']}
      version: #{identity['version']}
      role: #{identity['role']}
      base_model: #{identity['base_model']}
      adapter: #{identity['adapter']}
      adapter_sha256: #{identity['adapter_sha256'] || 'null'}

      ### CAPACITIES
      can: #{capacity['can'].join(', ')}
      cannot: #{capacity['cannot'].join(', ')}
      max_input_tokens: #{capacity['max_input_tokens']}
      max_output_tokens: #{capacity['max_output_tokens']}
      output_schema: #{capacity['output_schema']}

      ### DECISION
      status: #{status}
      reason_code: #{reason}
      next_hop: #{next_hop || 'null'}
      message: #{message}

      ### BODY
      #{body}
    TEXT
  end

  # A d1 result is already an envelope: the adapter stamps it, the model never
  # echoes a text contract.
  def d1_result(target, answers:, status: "accept", reason: "ok",
                next_hop: nil, message: "typed", body: nil, schema: nil)
    body = status == "accept" ? (body || "typed decision") : "" if body.nil?
    decision = Runes::Swarm::Decision.new(
      status: status, reason_code: reason, next_hop: next_hop,
      message: message, body: body
    )
    artifact = {
      "schema" => schema || target.capacity.output_schema,
      "answers" => answers,
      "decision" => {
        "status" => status.to_s,
        "reason_code" => reason.to_s,
        "next_hop" => next_hop&.to_s,
        "message" => message
      }
    }
    stamp = Runes::Swarm::Envelope.stamp(
      manifest: target, decision: decision, body: body
    )
    {
      ok: true, content: Runes::Json.generate(artifact), usage: nil,
      finish_reason: nil, status: :ok, error: nil,
      artifact: artifact, answers: answers, decision: decision,
      envelope: stamp, family: target.base_model, modalities: ["text"]
    }
  end

  def media_result(target, modality:, anchors:, sha:, content:,
                   artifact_modality: nil, schema: nil)
    artifact = {
      "schema" => schema || target.capacity.output_schema,
      "modality" => (artifact_modality || modality).to_s,
      "source_sha256" => sha,
      "anchors" => anchors,
      "content" => content
    }
    decision = Runes::Swarm::Decision.new(
      status: :accept, reason_code: :ok, body: content
    )
    stamp = Runes::Swarm::Envelope.stamp(
      manifest: target, decision: decision, body: content
    )
    {
      ok: true, content: content, usage: nil, finish_reason: nil,
      status: :ok, error: nil, artifact: artifact, anchors: anchors,
      source_sha256: sha, decision: decision, envelope: stamp,
      family: target.base_model,
      modalities: target.family.modalities.map(&:to_s)
    }
  end

  def resolve_body(value, prompt = nil)
    return value.call(prompt) if value.respond_to?(:call)

    if value.is_a?(Array)
      return value.length > 1 ? value.shift : value.first
    end

    value
  end

  # --------------------------------------------------------------- wiring

  def wire_text(agent_id, body: nil, status: "accept", reason: "ok",
                next_hop: nil, message: "ok", handler: nil, raw: false)
    target = fetch_manifest(agent_id)
    fake = ScriptedText.new do |prompt, _role|
      if handler
        handler.call(prompt)
      else
        value = resolve_body(body, prompt)
        if raw
          value
        else
          envelope(target, body: value, status: status, reason: reason,
                   next_hop: next_hop, message: message)
        end
      end
    end
    models[agent_id] = fake
    fake
  end

  def wire_d1(agent_id, &handler)
    target = fetch_manifest(agent_id)
    raise ArgumentError, "wire_d1 needs a handler" if handler.nil?

    fake = ScriptedD1.new do |state, questions, assigned|
      handler.call(state, questions, assigned || target)
    end
    models[agent_id] = fake
    fake
  end

  def wire_triage(agent_id: "triage.d1", modality: "text", intent: "answer",
                  scope: 0.9, risk: 0.1, sufficiency: 0.9,
                  shape: "answer-lite", unsafe: false, status: "accept",
                  reason: "ok", next_hop: nil, message: "triaged")
    wire_d1(agent_id) do |_state, questions, target|
      answers = questions.map do |question|
        id = question["id"].to_s
        value =
          case id
          when "modality" then modality
          when "intent" then intent
          when "scope" then scope
          when "risk" then risk
          when "sufficiency" then sufficiency
          when "shape" then shape
          when "unsafe" then unsafe
          end
        { "id" => id, "value" => value }
      end
      d1_result(target, answers: answers, status: status, reason: reason,
                next_hop: next_hop, message: message)
    end
  end

  def wire_judge(agent_id: "judge.d1", support: 0.9, contradiction: 0.05,
                 sufficiency: 0.9, choice: "a", support_a: 0.9,
                 support_b: 0.4, status: "accept", reason: "ok",
                 message: "judged")
    wire_d1(agent_id) do |_state, questions, target|
      ids = questions.map { |question| question["id"].to_s }
      answers =
        if ids.include?("support_a")
          [
            { "id" => "support_a", "value" => support_a },
            { "id" => "support_b", "value" => support_b },
            { "id" => "choice", "value" => choice }
          ]
        else
          [
            { "id" => "support", "value" => support },
            { "id" => "contradiction", "value" => contradiction },
            { "id" => "sufficiency", "value" => sufficiency }
          ]
        end
      d1_result(target, answers: answers, status: status, reason: reason,
                message: message)
    end
  end

  def wire_media(agent_id, modality:, anchors: ["image:1"],
                 sha: "a" * 64, content: "A concise perception.",
                 artifact_modality: nil, schema: nil, handler: nil)
    target = fetch_manifest(agent_id)
    fake = ScriptedMedia.new do |input, assigned|
      assigned ||= target
      if handler
        handler.call(input, assigned)
      else
        media_result(assigned, modality: modality, anchors: anchors, sha: sha,
                     content: content, artifact_modality: artifact_modality,
                     schema: schema)
      end
    end
    models[agent_id] = fake
    fake
  end

  def wire_clean_answer_lite(answer: "Le total est 128,40.",
                             support: 0.9, contradiction: 0.05)
    triage = wire_triage
    answerer = wire_text("answerer.grounded", body: answer)
    judge = wire_judge(support: support, contradiction: contradiction)
    { triage: triage, answerer: answerer, judge: judge }
  end

  def clean_run(**options)
    build_conductor(**options).run(task: TASK, evidence: EVIDENCE)
  end

  # ---------------------------------------------------------------- tests

  def test_clean_answer_lite_is_a_fully_checked_route
    fakes = wire_clean_answer_lite
    result = clean_run

    assert_equal :ok, result.status
    assert result.ok?
    assert_equal :answer_lite, result.shape
    assert_equal "Le total est 128,40.", result.final
    assert_equal %w[triage plan solve test review review verify verify],
                 result.route.map { |entry| entry["phase"] }
    assert_empty result.violations
    assert_equal 0, result.unvalidated_hops
    assert result.checkpoints.all?(&:passed?)
    assert_equal 4, result.call_count
    assert_equal 4, result.receipt.role_receipt_count
    assert_equal :accept, result.decision.status
    assert_equal 1, fakes[:triage].calls.size
    assert_equal 1, fakes[:answerer].calls.size
    refute_nil @ledger.read(:final)
    refute_nil @ledger.read(:plan)
    refute_nil @ledger.read(:review)
  end

  def test_every_route_entry_has_all_fourteen_gates_in_order
    wire_clean_answer_lite
    result = clean_run

    refute_empty result.route
    result.route.each do |entry|
      checkpoint = entry["checkpoint"]
      refute_nil checkpoint, "route entry #{entry['phase']} has no checkpoint"
      assert_equal Runes::Swarm::Checkpoint::GATES.map(&:to_s),
                   checkpoint["gates"].keys
      assert_equal 14, checkpoint["gates"].size
      assert_equal checkpoint["passed"], entry["status"] == "ok"
    end
  end

  def test_prompts_contain_one_micro_task_and_never_the_plan_or_transcript
    fakes = wire_clean_answer_lite
    clean_run

    prompt = fakes[:answerer].calls.first[:prompt]
    assert_equal 1, prompt.scan("### TASK").size
    assert_equal 1, prompt.scan("### OUTPUT CONTRACT").size
    refute_match(/plan\.v1/i, prompt)
    refute_match(/#\s*plan/i, prompt)
    refute_match(/transcript/i, prompt)
    refute_match(/proposal[-_]a/i, prompt)
    refute_match(/review\.v1/i, prompt)

    fakes[:triage].calls.each do |call|
      refute_match(/plan\.v1/i, Runes::Json.generate(call[:state]))
    end
  end

  def test_triage_decline_is_terminal_and_is_not_retried
    triage = wire_triage(status: "decline", reason: "out_of_scope")
    answerer = wire_text("answerer.grounded", body: "never called")
    judge = wire_judge

    result = clean_run

    assert_equal :declined, result.status
    assert result.control?
    assert_equal :out_of_scope, result.decision.reason_code
    # The selected shape is recorded on control stops, not dropped.
    assert_equal :escalate, result.shape
    assert_equal 1, triage.calls.size
    assert_empty answerer.calls
    assert_empty judge.calls
    assert_equal %w[triage], result.route.map { |entry| entry["phase"] }
  end

  def test_triage_escalation_uses_the_external_role
    wire_triage(status: "escalate", reason: "needs_frontier",
                next_hop: "frontier")
    escalation = ScriptedText.new { |_prompt, _role| "Frontier answer page:1." }
    models["escalation"] = escalation
    judge = wire_judge

    result = clean_run

    assert_equal :escalated, result.status
    assert result.control?
    assert_equal :needs_frontier, result.decision.reason_code
    assert_equal "Frontier answer page:1.", result.final
    assert_equal 1, escalation.calls.size
    assert_empty judge.calls
  end

  def test_unsafe_triage_escalates_instead_of_answering_locally
    wire_triage(unsafe: true, shape: "answer-lite")
    escalation = ScriptedText.new { |_prompt, _role| "External handling." }
    models["escalation"] = escalation
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = clean_run

    assert_equal :escalated, result.status
    assert_equal :needs_frontier, result.decision.reason_code
    assert_equal 1, escalation.calls.size
    assert_empty answerer.calls
  end

  def test_decide_returns_the_typed_artifact_without_a_text_call
    triage = wire_triage(shape: "decide", intent: "classify", modality: "text")
    answerer = wire_text("answerer.grounded", body: "must not run")
    judge = wire_judge

    result = build_conductor(shape: :decide).run(
      task: { "question" => "Classe ce document.", "modality" => "text" },
      evidence: EVIDENCE
    )

    assert_equal :ok, result.status
    assert_equal :decide, result.shape
    assert_includes result.final, "intent=classify"
    assert_equal %w[triage plan verify],
                 result.route.map { |entry| entry["phase"] }
    assert_equal 1, triage.calls.size
    assert_empty answerer.calls
    assert_empty judge.calls
  end

  def test_task_questions_turn_decide_into_a_typed_d1_decision
    triage = wire_triage(shape: "decide", intent: "classify", modality: "text")
    judge = wire_d1("judge.d1") do |_state, questions, target|
      answers = questions.map do |question|
        { "id" => question["id"],
          "value" => question["id"] == "intent" ? "cancel" : "unknown" }
      end
      d1_result(target, answers: answers)
    end
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor(shape: :decide, checks: { "must_match" => ["cancel"] }).run(
      task: { "question" => "Classe l'intention.", "modality" => "text",
              "questions" => [
                { "id" => "intent", "question" => "What is the intent?", "type" => "choice" }
              ] },
      evidence: EVIDENCE
    )

    assert_equal :ok, result.status, result.error
    assert_equal :decide, result.shape
    assert_equal "intent=cancel", result.final
    assert_equal %w[triage plan decide test verify],
                 result.route.map { |entry| entry["phase"] }
    assert_equal 1, triage.calls.size
    assert_equal 1, judge.calls.size
    assert_empty answerer.calls
    assert_includes result.route.map { |entry| entry["phase"] }, "test"
    refute_nil @ledger.read(:final)
  end

  def test_a_typed_decision_that_fails_the_checks_is_not_accepted
    wire_triage(shape: "decide", intent: "classify", modality: "text")
    judge = wire_d1("judge.d1") do |_state, questions, target|
      answers = questions.map { |question| { "id" => question["id"], "value" => "buy" } }
      d1_result(target, answers: answers)
    end
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor(shape: :decide, checks: { "must_match" => ["cancel"] }).run(
      task: { "question" => "Classe l'intention.", "modality" => "text",
              "questions" => [
                { "id" => "intent", "question" => "What is the intent?", "type" => "choice" }
              ] },
      evidence: EVIDENCE
    )

    assert_equal :unverified, result.status, result.error
    assert_equal 1, judge.calls.size
    assert_empty answerer.calls
    assert_equal %w[triage plan decide test verify],
                 result.route.map { |entry| entry["phase"] }
    assert(result.violations.any? { |item| item.code.to_s == "phrase_missing" })
  end

  def test_see_shape_perceives_before_answering
    triage = wire_triage(shape: "see", modality: "image")
    vision = wire_media("perceiver.vision", modality: "image",
                        content: "Invoice total 128,40.", anchors: ["page:1"])
    judge = wire_judge
    answerer = wire_text("answerer.grounded", body: "Le total est 128,40.")

    result = build_conductor.run(
      task: { "question" => TASK, "modality" => "image" },
      evidence: EVIDENCE,
      media: [{ "path" => "invoice.png", "modality" => "image" }]
    )

    assert_equal :ok, result.status
    assert_equal :see, result.shape
    assert_equal %w[triage plan perceive perception_judge solve test review review verify verify],
                 result.route.map { |entry| entry["phase"] }
    assert_equal 1, vision.calls.size
    assert_equal 1, triage.calls.size
    assert_equal 3, judge.calls.size
    assert_includes answerer.calls.first[:prompt], "Invoice total 128,40."
    refute_nil @ledger.read(:perception)
  end

  def test_hear_shape_uses_the_audio_triage_and_audio_role
    triage = wire_triage(agent_id: "triage.audio", shape: "answer-lite",
                         modality: "audio")
    audio = wire_media("perceiver.audio", modality: "audio",
                       content: "Appel: le total est 128,40.",
                       anchors: ["time:00:04"])
    wire_judge
    answerer = wire_text("answerer.grounded", body: "Le total est 128,40.")

    result = build_conductor.run(
      task: { "question" => TASK, "modality" => "audio" },
      evidence: EVIDENCE,
      media: [{ "path" => "call.wav", "modality" => "audio" }]
    )

    assert_equal :ok, result.status
    assert_equal :hear, result.shape
    assert_equal :audio, result.plan.steps.first.role
    assert_equal 1, triage.calls.size
    assert_equal 1, audio.calls.size
    assert_includes answerer.calls.first[:prompt], "Appel: le total"
  end

  def test_missing_media_declines_before_a_text_call
    wire_triage(shape: "see", modality: "image")
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor.run(
      task: { "question" => TASK, "modality" => "image" }, evidence: EVIDENCE
    )

    assert_equal :declined, result.status
    assert_includes %i[needs_vision missing_evidence needs_perception],
                    result.decision.reason_code
    assert_empty answerer.calls
    assert_equal %w[triage plan], result.route.map { |entry| entry["phase"] }
  end

  def test_a_missing_required_role_declines_without_a_generalist_fallback
    wire_triage
    judge = wire_judge
    conductor = build_conductor(registry: registry_without(:answerer), shape: :answer_lite)

    result = conductor.run(task: TASK, evidence: EVIDENCE)

    assert_equal :declined, result.status
    assert_equal :no_route, result.decision.reason_code
    assert_includes result.error.to_s, "answerer"
    assert_empty judge.calls
  end

  def test_a_missing_required_modality_role_declines
    wire_triage(shape: "see", modality: "image")
    conductor = build_conductor(registry: registry_without(:vision), shape: :see)

    result = conductor.run(
      task: { "question" => TASK, "modality" => "image" },
      evidence: EVIDENCE,
      media: [{ "path" => "invoice.png", "modality" => "image" }]
    )

    assert_equal :declined, result.status
    assert_equal :no_route, result.decision.reason_code
    assert_includes result.error.to_s, "vision"
  end

  def test_provenance_miss_is_unverified_and_stops_the_next_role
    wire_triage(shape: "see", modality: "image")
    wire_media("perceiver.vision", modality: "image", anchors: [],
               content: "Ungrounded caption.")
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor.run(
      task: { "question" => TASK, "modality" => "image" },
      evidence: EVIDENCE,
      media: [{ "path" => "invoice.png", "modality" => "image" }]
    )

    assert_equal :unverified, result.status
    assert(result.violations.any? { |item| item.code.to_s == "provenance_missing" })
    assert_empty answerer.calls
    assert_equal %w[triage plan perceive],
                 result.route.map { |entry| entry["phase"] }
  end

  def test_modality_mismatch_is_unverified
    wire_triage(shape: "see", modality: "image")
    wire_media("perceiver.vision", modality: "video",
               artifact_modality: "audio", content: "Wrong modality.")
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor.run(
      task: { "question" => TASK, "modality" => "video" },
      evidence: EVIDENCE,
      media: [{ "path" => "talk.mp4", "modality" => "video" }]
    )

    assert_equal :unverified, result.status
    assert(result.violations.any? { |item| item.code.to_s == "modality_mismatch" })
    assert_empty answerer.calls
  end

  def test_low_perception_sufficiency_declines_before_answering
    wire_triage(shape: "see", modality: "image")
    wire_media("perceiver.vision", modality: "image", content: "Blurry page.")
    wire_judge(sufficiency: 0.1)
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor.run(
      task: { "question" => TASK, "modality" => "image" },
      evidence: EVIDENCE,
      media: [{ "path" => "invoice.png", "modality" => "image" }]
    )

    assert_equal :declined, result.status
    assert_equal :missing_evidence, result.decision.reason_code
    assert_empty answerer.calls
    assert_equal %w[triage plan perceive perception_judge],
                 result.route.map { |entry| entry["phase"] }
  end

  def test_a_b_collapse_stops_before_selection
    wire_triage(shape: "answer-full")
    wire_text("ideator.direct", body: "Identical proposal with page:1.")
    wire_text("ideator.alternative", body: "Identical proposal with page:1.")
    judge = wire_judge

    result = clean_run

    assert_equal :proposal_collapse, result.status
    assert_match(/identical/, result.error)
    assert_equal 2, result.route.count { |entry| entry["phase"].to_s.start_with?("ideate") }
    assert_empty judge.calls
    assert_equal 2, @ledger.read_json(:proposals).size
  end

  def test_a_b_divergence_lets_the_judge_select_one_and_record_calibration
    wire_triage(shape: "answer-full")
    direct = wire_text("ideator.direct",
                       body: "Direct: verify the total on page:1.")
    alternative = wire_text("ideator.alternative",
                            body: "Alternative: recompute each line on page:1.")
    wire_judge(support_a: 0.9, support_b: 0.4, choice: "a")
    wire_text("answerer.grounded", body: "Le total est 128,40.")

    result = clean_run

    assert_equal :ok, result.status
    assert_equal :answer_full, result.shape
    assert_includes result.route.map { |entry| entry["phase"] }, "select"
    assert_equal 1, direct.calls.size
    assert_equal 1, alternative.calls.size
    calibration = @ledger.read_json(:calibration)
    select = calibration.find { |entry| entry["phase"] == "select" }
    refute_nil select
    assert_equal "a", select["choice"]
    assert_in_delta 0.9, select["support_a"]

    plan_text = @ledger.read(:plan)
    result.plan.anchors.each_value do |anchor|
      assert_equal 1, plan_text.scan(Regexp.new(Regexp.escape(anchor))).size
    end
    assert_includes direct.calls.first[:prompt], "[[proposal-a]]"
    refute_includes direct.calls.first[:prompt], "[[proposal-b]]"
    assert_includes alternative.calls.first[:prompt], "[[proposal-b]]"
    refute_includes alternative.calls.first[:prompt], "[[proposal-a]]"
  end

  def test_answerer_failure_with_one_repair_is_repaired
    checks = { "must_cite" => ["page:1"] }
    wire_triage
    wire_text("answerer.grounded", body: "Le total est 128,40.")
    wire_judge(support: 0.9, contradiction: 0.0)
    repairer = wire_text("repairer.bounded",
                         body: "Le total est 128,40. Citations: page:1")

    result = build_conductor(checks: checks).run(task: TASK, evidence: EVIDENCE)

    assert_equal :repaired, result.status
    assert_includes result.final, "page:1"
    assert_includes result.route.map { |entry| entry["phase"] }, "repair"
    assert_equal 1, repairer.calls.size
    assert_includes repairer.calls.first[:prompt], "citation_missing"
    refute_nil @ledger.read(:draft)
    refute_nil @ledger.read(:final)
  end

  def test_repair_returning_the_same_body_is_no_progress
    checks = { "must_cite" => ["page:1"] }
    wire_triage
    wire_text("answerer.grounded", body: "Le total est 128,40.")
    wire_judge(support: 0.9, contradiction: 0.0)
    wire_text("repairer.bounded", body: "Le total est 128,40.")

    result = build_conductor(checks: checks).run(task: TASK, evidence: EVIDENCE)

    assert_equal :no_progress, result.status
    assert_match(/same artifact/, result.error)
  end

  def test_a_failed_repair_is_repair_exhausted
    checks = { "must_cite" => ["page:1"] }
    wire_triage
    wire_text("answerer.grounded", body: "Le total est 128,40.")
    wire_judge(support: 0.9, contradiction: 0.0)
    wire_text("repairer.bounded", body: "Le total est 128,40. Voir le document.")

    result = build_conductor(checks: checks).run(task: TASK, evidence: EVIDENCE)

    assert_equal :repair_exhausted, result.status
    assert_match(/single repair/, result.error)
  end

  def test_critic_decline_routes_away_without_a_blind_repair
    wire_triage(shape: "answer-full")
    wire_text("ideator.direct", body: "Direct proposal with page:1.")
    wire_text("ideator.alternative", body: "Alternative proposal with page:1.")
    wire_judge(support_a: 0.9, support_b: 0.4, choice: "a")
    wire_text("answerer.grounded", body: "Le total est 128,40.")
    critic = wire_text("critic.claims", status: "decline", reason: "low_support")
    repairer = wire_text("repairer.bounded", body: "must not run")

    result = clean_run

    assert_equal :declined, result.status
    assert_equal :low_support, result.decision.reason_code
    assert_equal 1, critic.calls.size
    assert_empty repairer.calls
  end

  def test_low_calibrated_support_declines_instead_of_accepting
    wire_triage
    wire_text("answerer.grounded", body: "Le total est 128,40.")
    wire_judge(support: 0.2, contradiction: 0.1)
    repairer = wire_text("repairer.bounded", body: "must not run")

    result = clean_run

    assert_equal :declined, result.status
    assert_equal :low_support, result.decision.reason_code
    assert_empty repairer.calls
  end

  def test_finalizer_decline_leaves_the_verified_answer_standing
    wire_clean_answer_lite
    finalizer = wire_text("finalizer.concise", status: "decline",
                          reason: "low_confidence")

    result = clean_run

    assert_equal :ok, result.status
    assert_equal "Le total est 128,40.", result.final
    assert_equal 1, finalizer.calls.size
    assert_includes result.route.map { |entry| entry["phase"] }, "finalize"
  end

  def test_contract_identity_mismatch_is_unverified
    wire_triage
    answerer_manifest = fetch_manifest("answerer.grounded")
    answerer = wire_text(
      "answerer.grounded",
      handler: lambda do |_prompt|
        envelope(answerer_manifest, body: "Le total est 128,40.",
                 agent_id: "answerer.wrong")
      end
    )
    judge = wire_judge

    result = clean_run

    assert_equal :unverified, result.status
    assert_equal 1, answerer.calls.size
    assert_empty judge.calls
    assert(result.violations.any? { |item| item.code.to_s == "identity_mismatch" })
  end

  def test_a_failed_envelope_never_calls_the_next_role
    wire_triage
    # A malformed DECISION (unknown status) still fails the contract; plain
    # prose is a valid stamped accept under stamp mode and is covered by
    # test_plain_prose_is_stamped_as_an_accept.
    answerer = wire_text("answerer.grounded", raw: true,
                         body: "### DECISION\nstatus: maybe\nreason_code: ok\n\n### BODY\nx")
    judge = wire_judge

    result = clean_run

    assert_equal :unverified, result.status
    assert_equal 1, answerer.calls.size
    assert_empty judge.calls
    assert_equal %w[triage plan solve],
                 result.route.map { |entry| entry["phase"] }
  end

  def test_plain_prose_is_stamped_as_an_accept
    wire_triage
    answerer = wire_text("answerer.grounded", raw: true,
                         body: "128,40 EUR, cite doc:t1#p1.")
    wire_judge

    result = clean_run

    assert_equal :ok, result.status
    assert_equal :accept, result.decision.status
    assert_includes result.final.to_s, "128,40"
  end

  def test_require_evidence_declines_before_any_model_call
    triage = wire_triage
    result = build_conductor(require_evidence: true).run(task: TASK)

    assert_equal :declined, result.status
    assert_equal :missing_evidence, result.decision.reason_code
    assert_empty triage.calls
    assert_empty result.route
  end

  def test_max_calls_budget_declines_the_next_phase
    triage = wire_triage
    wire_text("answerer.grounded", body: "must not run")

    result = build_conductor(max_calls: 1).run(task: TASK, evidence: EVIDENCE)

    assert_equal :declined, result.status
    assert_equal :budget_exhausted, result.decision.reason_code
    assert_match(/call budget/, result.error)
    assert_equal 1, triage.calls.size
  end

  def test_max_steps_budget_declines_the_next_phase
    wire_triage
    answerer = wire_text("answerer.grounded", body: "must not run")

    result = build_conductor(max_steps: 1).run(task: TASK, evidence: EVIDENCE)

    assert_equal :declined, result.status
    assert_equal :budget_exhausted, result.decision.reason_code
    assert_match(/step budget/, result.error)
    assert_empty answerer.calls
  end

  def test_wall_clock_budget_declines_before_triage
    triage = wire_triage
    ticks = 0.0
    clock = lambda do
      ticks += 1.0
      ticks
    end

    result = build_conductor(max_wall_s: 0.5, clock: clock).run(
      task: TASK, evidence: EVIDENCE
    )

    assert_equal :declined, result.status
    assert_equal :budget_exhausted, result.decision.reason_code
    assert_match(/wall-clock/, result.error)
    assert_empty triage.calls
  end

  def test_result_to_h_is_json_safe_and_carries_the_ledger_artifacts
    wire_clean_answer_lite
    result = clean_run
    hash = result.to_h
    parsed = Runes::Json.parse(Runes::Json.generate(hash))

    assert_equal "ok", parsed["status"]
    assert_equal "answer_lite", parsed["shape"]
    assert_equal 0, parsed["unvalidated_hops"]
    assert_equal Runes::Swarm::Checkpoint::GATES.map(&:to_s),
                 parsed["checkpoints"].first["gates"].keys
    assert_equal parsed["route"].size, parsed["checkpoints"].size
    refute_nil @ledger.read_json(:checkpoints)
    refute_nil @ledger.read_json(:role_receipts)
    refute_nil @ledger.read_json(:identity)
    refute_nil @ledger.read_json(:capacities)
  end
end
