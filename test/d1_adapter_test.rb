# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class D1AdapterTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  def status(code = 0)
    Status.new(code)
  end

  def verdict(probability: 0.8, status: "accept", reason: "ok", body: "scope=answer")
    Runes::Json.generate(
      "answers" => [{ "id" => "scope", "probability" => probability, "value" => "answer" }],
      "status" => status,
      "reason_code" => reason,
      "body" => body
    )
  end

  def test_it_sends_typed_questions_and_no_sampler_flags
    seen = nil
    runner = lambda do |argv, stdin|
      seen = { argv: argv, stdin: stdin }
      [verdict, "", status]
    end

    adapter = Runes::LLM::D1Adapter.new(
      mode: :command,
      model: "LiquidAI/d1-2B",
      cli: "/tmp/d1_cli.py",
      python: "/bin/sh",
      runner: runner
    )

    result = adapter.system_one(
      { "task" => "Quel est le total ?" },
      [{ "id" => "scope", "question" => "Is this in scope?", "type" => "probability" }]
    )

    assert result[:ok]
    assert_equal "LiquidAI/d1-2B", result[:family]
    assert_equal ["text"], result[:modalities]
    assert_equal "scope", result[:answers].first["id"]
    assert_in_delta 0.8, result[:answers].first["probability"]
    assert result[:decision].accept?
    assert_equal "scope=answer", result[:decision].body

    assert_equal "/bin/sh", seen[:argv][0]
    assert_equal "/tmp/d1_cli.py", seen[:argv][1]
    assert_equal "LiquidAI/d1-2B", seen[:argv][seen[:argv].index("--model") + 1]
    assert_includes seen[:argv], "--state"
    assert_includes seen[:argv], "--questions"
    refute_includes seen[:argv], "--temperature"
    refute_includes seen[:argv], "--max-tokens"
    refute_includes seen[:argv], "--top-k"
    assert_equal "", seen[:stdin]

    questions = Runes::Json.parse(seen[:argv][seen[:argv].index("--questions") + 1])
    assert_equal "scope", questions.first["id"]
    assert_equal "Is this in scope?", questions.first["question"]
  end

  def test_it_rejects_a_probability_outside_the_unit_interval
    runner = ->(_argv, _stdin) { [verdict(probability: 1.4), "", status] }
    adapter = Runes::LLM::D1Adapter.new(
      mode: :command, model: "LiquidAI/d1-2B", cli: "/tmp/d1_cli.py",
      python: "/bin/sh", runner: runner
    )

    result = adapter.system_one("state", [{ "id" => "scope", "question" => "Scope?" }])

    refute result[:ok]
    assert_equal :error, result[:status]
    assert_includes result[:error], "outside [0, 1]"
  end

  def test_a_non_json_answer_is_a_typed_failure
    runner = ->(_argv, _stdin) { ["not json", "", status] }
    adapter = Runes::LLM::D1Adapter.new(
      mode: :command, model: "LiquidAI/d1-2B", cli: "/tmp/d1_cli.py",
      python: "/bin/sh", runner: runner
    )

    result = adapter.system_one("state", [{ "id" => "scope", "question" => "Scope?" }])

    refute result[:ok]
    assert_equal :error, result[:status]
    assert_includes result[:error], "non-JSON"
  end

  def test_media_is_routed_by_family
    Dir.mktmpdir("d1-") do |dir|
      audio = File.join(dir, "clip.wav")
      File.write(audio, "RIFF")
      seen = nil
      runner = lambda do |argv, _stdin|
        seen = argv
        [verdict, "", status]
      end

      text = Runes::LLM::D1Adapter.new(
        mode: :command, model: "LiquidAI/d1-2B", cli: "/tmp/d1_cli.py",
        python: "/bin/sh", runner: runner
      )
      declined = text.system_one("state", [{ "id" => "x", "question" => "x?" }], media: audio)

      refute declined[:ok]
      assert_equal :declined, declined[:status]
      assert_equal :out_of_modality, declined[:decision].reason_code

      omni = Runes::LLM::D1Adapter.new(
        mode: :command, model: "LiquidAI/d1-Omni-2B", cli: "/tmp/d1_cli.py",
        python: "/bin/sh", runner: runner
      )
      accepted = omni.system_one("state", [{ "id" => "x", "question" => "x?" }], media: audio)

      assert accepted[:ok]
      assert_includes seen, "--media"
      assert_equal audio, seen[seen.index("--media") + 1]
    end
  end

  def test_a_manifest_stamps_the_envelope
    manifest = Runes::Swarm::Manifest.load(File.join(__dir__, "..", "config", "agents", "triage.json"))
    runner = ->(_argv, _stdin) { [verdict, "", status] }
    adapter = Runes::LLM::D1Adapter.new(
      mode: :command, model: "LiquidAI/d1-2B", cli: "/tmp/d1_cli.py",
      python: "/bin/sh", runner: runner
    )

    result = adapter.system_one(
      "state", [{ "id" => "scope", "question" => "Scope?" }], manifest: manifest
    )

    assert result[:ok]
    assert_instance_of Runes::Swarm::Envelope, result[:envelope]
    assert_equal "triage.d1", result[:envelope].identity.agent_id
    assert_equal "verdict.v1", result[:envelope].capacity.output_schema
    assert result[:envelope].decision.accept?
    assert_equal "scope=answer", result[:envelope].body
  end

  def test_a_typed_decline_is_not_a_transport_error
    manifest = Runes::Swarm::Manifest.load(File.join(__dir__, "..", "config", "agents", "triage.json"))
    runner = lambda do |_argv, _stdin|
      [Runes::Json.generate(
        "answers" => [{ "id" => "scope", "probability" => 0.1 }],
        "status" => "decline",
        "reason_code" => "out_of_scope",
        "message" => "outside the family"
      ), "", status]
    end
    adapter = Runes::LLM::D1Adapter.new(
      mode: :command, model: "LiquidAI/d1-2B", cli: "/tmp/d1_cli.py",
      python: "/bin/sh", runner: runner
    )

    result = adapter.system_one(
      "state", [{ "id" => "scope", "question" => "Scope?" }], manifest: manifest
    )

    assert result[:ok]
    assert result[:decision].decline?
    assert_equal :out_of_scope, result[:decision].reason_code
    assert_equal "", result[:envelope].body
  end

  def test_a_missing_binary_is_infrastructure
    adapter = Runes::LLM::D1Adapter.new(
      mode: :command,
      model: "LiquidAI/d1-2B",
      cli: File.join(Dir.tmpdir, "definitely-missing-d1-cli.py"),
      python: "/definitely/missing/python"
    )

    refute adapter.available?
    result = adapter.system_one("state", [{ "id" => "x", "question" => "x?" }])

    refute result[:ok]
    assert_equal :infra, result[:status]
    assert_includes result[:error], "not found"
  end

  def test_an_unknown_decision_status_is_a_typed_failure
    runner = lambda do |_argv, _stdin|
      [Runes::Json.generate("answers" => [], "status" => "wat", "reason_code" => "ok"), "", status]
    end
    adapter = Runes::LLM::D1Adapter.new(
      mode: :command, model: "LiquidAI/d1-2B", cli: "/tmp/d1_cli.py",
      python: "/bin/sh", runner: runner
    )

    result = adapter.system_one("state", [{ "id" => "scope", "question" => "Scope?" }])

    refute result[:ok]
    assert_equal :error, result[:status]
    assert_includes result[:error], "unknown status"
  end

  def test_from_env_selects_the_omni_checkpoint
    adapter = Runes::LLM::D1Adapter.from_env(
      { "LFM3_D1_MODEL" => "LiquidAI/d1-2B",
        "LFM3_D1_OMNI_MODEL" => "LiquidAI/d1-Omni-2B" },
      omni: true
    )

    assert_equal "LiquidAI/d1-Omni-2B", adapter.model_name
  end
end
