require "test_helper"

class PacketTest < ActiveSupport::TestCase
  test "parsed exposes the JSON payload and pretty_payload formats it" do
    packet = packets(:prompt_packet)
    assert_equal "req-1", packet.parsed["request_id"]
    assert_match(/"request_id": "req-1"/, packet.pretty_payload)
  end

  test "parsed is nil (not an exception) for non-JSON payloads" do
    packet = Packet.new(topic: "runes/prompts/response", kind: "response", payload: "plain text")
    assert_nil packet.parsed
    assert_equal "plain text", packet.pretty_payload
  end

  test "headline summarises the interesting field per kind" do
    assert_equal "write a greeting file", packets(:prompt_packet).headline
    assert_equal "plan_ready", packets(:progress_packet).headline
    assert_includes packets(:response_packet).headline, "Plan for"
    assert_equal "complete — Plan for: write a greeting file", packets(:journal_packet).headline
  end

  test "correlation_key is the request id, and nil without one" do
    assert_equal "request:req-1", packets(:progress_packet).correlation_key
    assert_nil packets(:global_response_packet).correlation_key
    assert_nil Packet.new(topic: "x", kind: "other").correlation_key
  end

  test "scopes filter by agent, kind, request and id cursor" do
    assert_includes Packet.for_agent("runes-alpha"), packets(:progress_packet)
    assert_equal [packets(:progress_packet)], Packet.of_kind("progress").to_a
    assert_equal [packets(:progress_packet)], Packet.for_request("req-1").of_kind("progress").to_a

    # Fixture ids are hashed, not insertion-ordered, so compare against the
    # actual id range rather than a fixture's position.
    assert_equal Packet.count, Packet.after_id(Packet.minimum(:id) - 1).count
    assert_equal Packet.count, Packet.before_id(Packet.maximum(:id) + 1).count
    assert_empty Packet.after_id(Packet.maximum(:id))
  end

  test "size_label is human readable" do
    assert_equal "62 B", packets(:prompt_packet).size_label
    assert_equal "2.0 KiB", Packet.new(payload_bytes: 2048).size_label
  end

  test "kind must be one of the known classifications" do
    packet = Packet.new(topic: "runes/x", kind: "nonsense")
    refute packet.valid?
    assert_includes packet.errors[:kind], "is not included in the list"
  end

  test "the claim/lease kinds are gone" do
    %w[claim started session_claim session_started].each do |kind|
      refute_includes Packet::KINDS, kind
    end
    refute Packet.column_names.include?("lease_id"), "the lease_id column was removed"
  end

  test "summary_payload bounds the rendered body" do
    small = Packet.new(payload: "x" * 100)
    assert_equal "x" * 100, small.summary_payload
    refute small.summary_truncated?

    large = Packet.new(payload: "y" * (Packet::SUMMARY_BYTES + 500))
    assert_operator large.summary_payload.bytesize, :<=, Packet::SUMMARY_BYTES + 4
    assert large.summary_truncated?
  end
end
