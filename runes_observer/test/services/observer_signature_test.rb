require "test_helper"
require "tmpdir"

# doc5.md O0.3. `agent_id` used to be whatever the payload claimed; these are
# the four verdicts the observer can now record, and the guarantee that the
# untrustworthy ones never read as trust.
class ObserverSignatureTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("runes-sig-")
    @alice = Runes::Security::Identity.load_or_create(agent_id: "alice", dir: @dir)
    @mallory = Runes::Security::Identity.load_or_create(agent_id: "mallory", dir: @dir)
    @store = Runes::Security::TrustStore.new
    @store.add("alice", @alice.public_key_pem)
    ObserverSignature.reset_cache!
  end

  teardown do
    ObserverSignature.reset_cache!
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) && @dir.start_with?(Dir.tmpdir)
  end

  test "a plain payload is unsigned, and says so instead of guessing" do
    result = ObserverSignature.check({ "request_id" => "r1", "agent" => "alice" }, store: @store)

    assert_equal "unsigned", result.state
    assert_nil result.fingerprint
    assert_equal "alice", result.claimed_agent
    refute result.signed?
  end

  test "a signature from a trusted key is verified" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @alice)

    result = ObserverSignature.check(signed, store: @store)

    assert_equal "verified", result.state
    assert_equal @alice.fingerprint.to_s, result.fingerprint
    assert_equal "alice", result.claimed_agent
    assert result.verified?
  end

  test "a signature from a key the store does not hold is untrusted, not verified" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @mallory)

    result = ObserverSignature.check(signed, store: @store)

    assert_equal "untrusted", result.state
    assert_equal :unknown_key, result.reason
    refute result.verified?
  end

  test "an empty trust store trusts nothing" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @alice)

    result = ObserverSignature.check(signed, store: Runes::Security::TrustStore.new)

    assert_equal "untrusted", result.state
  end

  test "a tampered payload is invalid" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @alice)

    result = ObserverSignature.check(signed.merge("prompt" => "transfer everything"), store: @store)

    assert_equal "invalid", result.state
    assert_equal :bad_signature, result.reason
  end

  test "another key cannot claim a trusted fingerprint" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @mallory)
    forged = signed.merge("kid" => @alice.fingerprint.to_s)

    assert_equal "invalid", ObserverSignature.check(forged, store: @store).state
  end

  test "a malformed signature is invalid, never verified" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @alice)

    assert_equal "invalid", ObserverSignature.check(signed.merge("sig" => "AAAA"), store: @store).state
    assert_equal "invalid", ObserverSignature.check(signed.merge("alg" => "rot13"), store: @store).state
  end

  # A busy fabric replays retained packets on every reconnect; re-verifying
  # identical bytes each time is the waste the memo exists to prevent.
  test "the same signed payload is verified once" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @alice)
    calls = 0
    original = Runes::Security::Envelope.method(:verify!)
    Runes::Security::Envelope.define_singleton_method(:verify!) do |*args, **kwargs|
      calls += 1
      original.call(*args, **kwargs)
    end
    begin
      2.times { assert_equal "verified", ObserverSignature.check(signed, store: @store).state }
      assert_equal 1, calls
      assert_equal 1, ObserverSignature.cache_size
    ensure
      Runes::Security::Envelope.define_singleton_method(:verify!, original)
    end
  end

  test "a broken verifier cannot read as trust" do
    signed = Runes::Security::Envelope.sign({ "agent" => "alice", "prompt" => "hi" }, @alice)
    original = Runes::Security::Envelope.method(:verify!)
    Runes::Security::Envelope.define_singleton_method(:verify!) { |*_a, **_k| raise TypeError, "boom" }
    begin
      assert_equal "invalid", ObserverSignature.check(signed, store: @store).state
    ensure
      Runes::Security::Envelope.define_singleton_method(:verify!, original)
    end
  end

  test "the trust directory and require-signatures mode come from the environment" do
    previous_dir = ENV["RUNES_OBSERVER_TRUST_DIR"]
    previous_require = ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"]
    begin
      ENV["RUNES_OBSERVER_TRUST_DIR"] = @dir
      assert_equal @dir, ObserverSignature.trust_dir

      ENV.delete("RUNES_OBSERVER_TRUST_DIR")
      ENV["RUNES_TRUST_DIR"] = @dir
      assert_equal @dir, ObserverSignature.trust_dir

      ENV.delete("RUNES_TRUST_DIR")
      assert_includes ObserverSignature.trust_dir, File.join("config", "trust")

      ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"] = "1"
      assert ObserverSignature.require_signatures?
      ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"] = "off"
      refute ObserverSignature.require_signatures?
    ensure
      previous_dir.nil? ? ENV.delete("RUNES_OBSERVER_TRUST_DIR") : ENV["RUNES_OBSERVER_TRUST_DIR"] = previous_dir
      previous_require.nil? ? ENV.delete("RUNES_OBSERVER_REQUIRE_SIGNATURES") : ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"] = previous_require
    end
  end
end
