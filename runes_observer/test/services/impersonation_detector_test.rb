require "test_helper"
require "tmpdir"

# doc5.md O0.3: one `agent_id`, two keys, is the single most interesting
# security event a shared broker can show you. These tests build that history
# by hand and ask what the observer would say about it.
class ImpersonationDetectorTest < ActiveSupport::TestCase
  setup do
    Packet.delete_all
    Agent.delete_all
    @dir = Dir.mktmpdir("runes-imp-")
    @alice = Runes::Security::Identity.load_or_create(agent_id: "runes-alpha", dir: @dir)
    @mallory = Runes::Security::Identity.load_or_create(agent_id: "runes-mallory", dir: @dir)
    @store = Runes::Security::TrustStore.new
    @store.add("runes-alpha", @alice.public_key_pem)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) && @dir.start_with?(Dir.tmpdir)
  end

  test "one agent under two keys is a split identity" do
    packet("runes-alpha", @alice.fingerprint.to_s, 3)
    packet("runes-alpha", @mallory.fingerprint.to_s, 1)

    findings = ImpersonationDetector.call(store: @store)

    assert_equal 1, findings.size
    finding = findings.first
    assert_equal :split_identity, finding.kind
    assert_equal "runes-alpha", finding.agent_id
    assert_equal 2, finding.fingerprints.size
    assert_equal 4, finding.packets
    assert_includes finding.description, "2 different keys"
  end

  test "one agent under its trusted key is not a finding" do
    packet("runes-alpha", @alice.fingerprint.to_s, 5)

    assert_empty ImpersonationDetector.call(store: @store)
    refute ImpersonationDetector.any?(store: @store)
  end

  test "a valid signature by a key the store does not hold for that agent is a wrong-key finding" do
    packet("runes-alpha", @mallory.fingerprint.to_s, 2)

    finding = ImpersonationDetector.call(store: @store).first

    assert_equal :wrong_key, finding.kind
    assert_equal @alice.fingerprint.to_s, finding.trusted_fingerprint
    assert_includes finding.description, "does not hold for it"
  end

  test "an agent the trust store has never heard of is not accused" do
    packet("runes-unknown", @mallory.fingerprint.to_s, 1)

    assert_empty ImpersonationDetector.call(store: @store)
  end

  test "unsigned packets cannot be impersonation" do
    packet("runes-alpha", nil, 4)

    assert_empty ImpersonationDetector.call(store: @store)
  end

  test "findings carry the window they were seen in" do
    packet("runes-alpha", @alice.fingerprint.to_s, 1, at: 3.hours.ago)
    packet("runes-alpha", @mallory.fingerprint.to_s, 1, at: 10.minutes.ago)

    finding = ImpersonationDetector.call(store: @store).first

    assert_in_delta 3.hours.ago.to_f, finding.first_seen.to_f, 60
    assert_in_delta 10.minutes.ago.to_f, finding.last_seen.to_f, 60
  end

  private

  def packet(agent_id, fingerprint, count, at: Time.current)
    count.times do |i|
      Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                     agent_id: agent_id, request_id: "#{agent_id}-#{fingerprint.to_s[0, 6]}-#{i}",
                     signature_state: fingerprint ? "verified" : "unsigned",
                     key_fingerprint: fingerprint, occurred_at: at, received_at: at)
    end
  end
end
