# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/security"

# Signed-envelope authenticity was already covered; freshness and forgery were
# not (doc5.md S5-4 residual and D5-4). A signature proves WHO sent a payload;
# without a timestamp and nonce it does not prove WHEN, so a captured envelope
# replays forever. These tests pin both halves.
class EnvelopeFreshnessTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("runes-env-")
    @alice = Runes::Security::Identity.load_or_create(agent_id: "alice", dir: @dir)
    @mallory = Runes::Security::Identity.load_or_create(agent_id: "mallory", dir: @dir)
    @store = Runes::Security::TrustStore.new
    @store.add("alice", @alice.public_key_pem)
    @guard = Runes::Security::NonceCache.new
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) && @dir.start_with?(Dir.tmpdir)
  end

  # --- D5-4: forgery, the negative test the suite was missing -------------

  def test_an_envelope_signed_by_another_key_cannot_claim_a_trusted_kid
    signed = Runes::Security::Envelope.sign({ "prompt" => "do it" }, @mallory)
    forged = signed.merge("kid" => @alice.fingerprint.to_s)

    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(forged, @store)
    end
    assert_equal :bad_signature, error.reason
  end

  def test_a_tampered_payload_fails
    signed = Runes::Security::Envelope.sign({ "prompt" => "do it" }, @alice)

    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed.merge("prompt" => "do something else"), @store)
    end
    assert_equal :bad_signature, error.reason
  end

  # --- replay ------------------------------------------------------------

  def test_a_fresh_envelope_verifies_once_and_then_is_refused_as_a_replay
    signed = Runes::Security::Envelope.sign({ "prompt" => "do it" }, @alice, fresh: true)

    first = Runes::Security::Envelope.verify!(signed, @store, replay_guard: @guard)
    assert_equal "do it", first["prompt"]

    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, @store, replay_guard: @guard)
    end
    assert_equal :replayed, error.reason, "the same bytes must not be accepted twice"
  end

  def test_a_stale_envelope_is_refused
    signed = Runes::Security::Envelope.sign({ "prompt" => "do it" }, @alice,
                                            fresh: true, ts: Time.now.to_i - 600)

    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, @store, replay_guard: @guard)
    end
    assert_equal :stale, error.reason
  end

  def test_a_future_envelope_is_refused_too
    signed = Runes::Security::Envelope.sign({ "prompt" => "do it" }, @alice,
                                            fresh: true, ts: Time.now.to_i + 600)

    assert_equal :stale, assert_raises(Runes::Security::VerificationError) {
      Runes::Security::Envelope.verify!(signed, @store, replay_guard: @guard)
    }.reason
  end

  # --- compatibility ------------------------------------------------------

  def test_a_signed_envelope_without_freshness_still_verifies_by_default
    signed = Runes::Security::Envelope.sign({ "prompt" => "hi" }, @alice)

    payload = Runes::Security::Envelope.verify!(signed, @store, replay_guard: @guard)
    assert_equal "hi", payload["prompt"]
  end

  def test_strict_mode_refuses_an_envelope_with_no_freshness
    signed = Runes::Security::Envelope.sign({ "prompt" => "hi" }, @alice)

    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, @store, require_fresh: true, replay_guard: @guard)
    end
    assert_equal :missing_freshness, error.reason
  end

  # --- the nonce cache ----------------------------------------------------

  def test_the_nonce_cache_is_bounded_and_expires
    cache = Runes::Security::NonceCache.new(ttl: 60, max: 3)
    now = Time.now.to_i

    assert cache.check_and_record("a", now)
    refute cache.check_and_record("a", now), "a nonce is accepted once"
    assert cache.check_and_record("b", now)
    assert cache.check_and_record("c", now)
    assert cache.check_and_record("d", now)
    assert_operator cache.size, :<=, 3, "the cache must stay bounded"
    refute cache.check_and_record("", now), "an empty nonce is never accepted"
    assert cache.check_and_record("a", now + 120), "an expired nonce may be reused"
  end

  def test_rpc_auth_still_exposes_its_nonce_cache
    assert_equal Runes::Security::NonceCache, Runes::Security::RPCAuth::NonceCache
  end
end
