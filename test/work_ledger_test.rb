# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class WorkLedgerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("runes-ledger-")
    @ledger = Runes::WorkLedger.new(root: @root, run_id: "g1-2x-s0")
  end

  def teardown
    FileUtils.remove_entry(@root, true) if @root && Dir.exist?(@root)
  end

  def test_it_writes_and_reads_artifacts_by_logical_name
    @ledger.write(:task, "question")
    @ledger.write(:draft, "answer")

    assert_equal "question", @ledger.read(:task)
    assert_equal "answer", @ledger.read(:draft)
    assert @ledger.artifact?(:draft)
    assert_nil @ledger.read(:final)
    refute @ledger.artifact?(:final)
  end

  def test_it_round_trips_json
    @ledger.write_json(:evidence, [{ "tool" => "search", "result" => { "ok" => true } }])

    parsed = @ledger.read_json(:evidence)
    assert_equal "search", parsed.first["tool"]
    assert_equal true, parsed.first["result"]["ok"]
  end

  def test_it_hashes_artifacts_and_updates_the_manifest
    @ledger.write(:task, "abc")

    assert_equal Runes::SHA256.hex("abc"), @ledger.sha(:task)
    assert_nil @ledger.sha(:final)

    @ledger.update_manifest("arm" => "2x", calls: 2)
    assert_equal "2x", @ledger.manifest["arm"]
    assert_equal 2, @ledger.manifest["calls"]
  end

  def test_it_preserves_a_truncated_draft_and_records_it
    @ledger.write(:draft, "cut off in the middle")
    @ledger.preserve_cutoff!(:draft)

    assert_equal "cut off in the middle", @ledger.read(:"draft.cutoff")
    assert_equal "cutoff_preserved", @ledger.transcript.last["event"]
  end

  def test_it_appends_transcript_events_without_feedback
    @ledger.append_transcript("call_finished", role: "solver", status: "ok")
    @ledger.append_transcript("run_finished", status: "ok")

    events = @ledger.transcript
    assert_equal %w[call_finished run_finished], events.map { |entry| entry["event"] }
    assert_equal "solver", events.first["role"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, events.first["at"])
  end

  def test_transcript_appends_are_serialized
    threads = 2.times.map do |index|
      Thread.new do
        20.times { |n| @ledger.append_transcript("event", thread: index, n: n) }
      end
    end
    threads.each(&:join)

    assert_equal 40, @ledger.transcript.size
  end

  def test_it_snapshots_artifacts_into_a_doc_store
    @ledger.write(:task, "snapshot me")
    @ledger.write_json(:evidence, [])
    store = Runes::DocStore.new(root: Dir.mktmpdir("runes-snapshot-"))

    snapshot = @ledger.snapshot!(store)

    assert_equal Runes::SHA256.hex("snapshot me"), snapshot["task"][:sha]
    assert File.file?(snapshot["task"][:path])
    assert_equal snapshot["task"][:sha], @ledger.manifest["snapshot"]["task"]["sha"]
  ensure
    FileUtils.remove_entry(store.root, true) if store && Dir.exist?(store.root)
  end

  def test_it_refuses_unknown_sections_and_unsafe_run_ids
    assert_raises(Runes::WorkLedger::InvalidName) { @ledger.write(:unknown, "x") }
    assert_raises(Runes::WorkLedger::InvalidName) do
      Runes::WorkLedger.new(root: @root, run_id: "../escape")
    end
  end

  def test_it_refuses_oversized_artifacts
    assert_raises(Runes::WorkLedger::TooLarge) do
      @ledger.write(:draft, "x" * (Runes::WorkLedger::MAX_ARTIFACT_BYTES + 1))
    end
  end

  def test_it_reports_invalid_json
    @ledger.write(:evidence, "{not json")

    assert_raises(Runes::WorkLedger::Error) { @ledger.read_json(:evidence) }
  end

  def test_it_exposes_the_swarm_contract_sections
    expected = {
      identity: "identity.json",
      capacities: "capacities.json",
      decision: "decision.json",
      decline: "decline.md",
      checkpoints: "checkpoints.json",
      role_receipts: "role_receipts.json"
    }

    expected.each do |name, filename|
      assert_equal filename, Runes::WorkLedger::FILES[name]
    end
  end

  def test_it_round_trips_the_swarm_contract_artifacts
    identity = {
      "assigned" => { "agent_id" => "answerer.grounded", "version" => "1.0.0" },
      "echoed" => { "agent_id" => "answerer.grounded", "version" => "1.0.0" }
    }
    capacities = {
      "assigned" => { "can" => %w[read_evidence cite] },
      "echoed" => { "can" => %w[read_evidence cite] }
    }
    decision = { "status" => "accept", "reason_code" => "ok" }
    checkpoints = [{ "step" => 1, "role" => "answerer", "passed" => true }]
    role_receipts = [{ "role" => "answerer", "status" => "ok" }]

    @ledger.write_json(:identity, identity)
    @ledger.write_json(:capacities, capacities)
    @ledger.write_json(:decision, decision)
    @ledger.write(:decline, "reason: missing_evidence\nnext_hop: human\n")
    @ledger.write_json(:checkpoints, checkpoints)
    @ledger.write_json(:role_receipts, role_receipts)

    assert_equal identity, @ledger.read_json(:identity)
    assert_equal capacities, @ledger.read_json(:capacities)
    assert_equal decision, @ledger.read_json(:decision)
    assert_equal "reason: missing_evidence\nnext_hop: human\n", @ledger.read(:decline)
    assert_equal checkpoints, @ledger.read_json(:checkpoints)
    assert_equal role_receipts, @ledger.read_json(:role_receipts)
    %i[identity capacities decision decline checkpoints role_receipts].each do |name|
      assert @ledger.artifact?(name), "expected #{name} to be written"
    end
  end

  def test_it_snapshots_the_swarm_contract_artifacts
    @ledger.write_json(:identity, { "agent_id" => "answerer.grounded" })
    @ledger.write_json(:capacities, { "can" => %w[read_evidence] })
    @ledger.write_json(:decision, { "status" => "accept" })
    @ledger.write(:decline, "none")
    @ledger.write_json(:checkpoints, [{ "step" => 1 }])
    @ledger.write_json(:role_receipts, [{ "role" => "answerer" }])
    store = Runes::DocStore.new(root: Dir.mktmpdir("runes-snapshot-"))

    snapshot = @ledger.snapshot!(store)

    %w[identity capacities decision decline checkpoints role_receipts].each do |name|
      assert snapshot.key?(name), "expected #{name} in the snapshot"
      assert File.file?(snapshot[name][:path])
    end
  ensure
    FileUtils.remove_entry(store.root, true) if store && Dir.exist?(store.root)
  end
end
