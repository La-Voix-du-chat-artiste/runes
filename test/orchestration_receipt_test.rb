# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class OrchestrationReceiptTest < Minitest::Test
  def test_role_receipt_records_hashes_and_sizes_without_raw_text
    receipt = Runes::RoleReceipt.new(
      role: :answerer,
      agent_id: "answerer.grounded",
      version: "1.0.0",
      decision: { "status" => "accept", "reason_code" => "ok" },
      status: :ok,
      prompt: "one micro-task",
      completion: "the answer",
      elapsed_s: 1.234
    )

    assert_equal "answerer", receipt.role
    assert_equal Runes::SHA256.hex("one micro-task"), receipt.prompt_sha
    assert_equal 14, receipt.prompt_chars
    assert_equal Runes::SHA256.hex("the answer"), receipt.completion_sha
    assert_equal 10, receipt.completion_chars
    assert_equal 1.234, receipt.elapsed_s
    assert_equal "accept", receipt.decision["status"]
    assert receipt.frozen?
  end

  def test_role_receipt_accepts_explicit_hashes_and_an_empty_completion
    receipt = Runes::RoleReceipt.new(
      role: :critic,
      prompt_sha: "a" * 64,
      prompt_chars: 10,
      completion_sha: nil,
      completion_chars: 0
    )

    assert_equal "a" * 64, receipt.prompt_sha
    assert_equal 10, receipt.prompt_chars
    assert_nil receipt.completion_sha
    assert_equal 0, receipt.completion_chars
    assert_nil receipt.decision
  end

  def test_run_receipt_aggregates_role_receipts
    receipt = Runes::RunReceipt.new(run_id: "g1-2x-s0", arm: "2x", case_id: "G1")
    added = receipt.add_role_receipt(
      role: :answerer,
      agent_id: "answerer.grounded",
      version: "1.0.0",
      adapter_sha256: nil,
      decision: { "status" => "accept", "reason_code" => "ok" },
      status: :ok,
      prompt_sha: "b" * 64,
      completion_sha: "c" * 64,
      elapsed_s: 1.2
    )

    assert_same added, receipt.role_receipts.first
    assert_equal 1, receipt.role_receipt_count
    hash = receipt.to_h
    assert_equal 1, hash["role_receipt_count"]
    assert_equal "answerer", hash["role_receipts"].first["role"]
    assert_equal "accept", hash["role_receipts"].first["decision"]["status"]
  end
end
