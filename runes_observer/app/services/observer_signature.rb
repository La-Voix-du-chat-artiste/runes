# Who really published this packet (doc5.md O0.3, roadmap O0.2's remaining
# columns).
#
# `PacketRecorder` used to take the payload's `agent` field at face value, so
# the observer could show a name and had no way to say whether anything backed
# it. The fleet already signs envelopes with per-agent Ed25519 identities
# (`Runes::Security::Envelope`) against a `TrustStore` on disk, and no other
# component in the project is better placed to notice that one `agent_id` is
# being published under two different keys.
#
# Four states, and nothing in between:
#
#   unsigned   no sig/alg/kid — most fabric traffic, or a payload we cannot parse
#   verified   signature checks out against a key in the trust store
#   untrusted  signed with a key the trust store does not have. The claim may
#              be honest, but nothing here can confirm it, so it is not trusted
#   invalid    provably wrong: bad signature, malformed, unknown algorithm
#
# `verify!` is called with `require_fresh: false` deliberately. Freshness and
# replay matter when a message is about to *cause work*; the observer is a
# witness, and a stale-but-authentic packet is still authentic history. Passing
# a replay guard here would also make the state depend on read order, which is
# exactly what a witness must not do.
class ObserverSignature
  STATES = %w[unsigned verified untrusted invalid].freeze
  # VerificationError reasons that mean "we cannot confirm this signer" as
  # opposed to "this is provably wrong".
  UNTRUSTED_REASONS = %i[unknown_key].freeze
  MAX_CACHE = 512

  Result = Struct.new(:state, :fingerprint, :claimed_agent, :reason, keyword_init: true) do
    def signed? = state != "unsigned"
    def verified? = state == "verified"
    def trusted? = %w[verified].include?(state)
  end

  @cache = {}
  @cache_mutex = Mutex.new
  @store = nil

  class << self
    def check(payload_hash, store: nil)
      return unsigned(payload_hash) unless signed?(payload_hash)

      store ||= trust_store
      fingerprint = payload_hash[Runes::Security::Envelope::KID_FIELD].to_s
      digest = digest_of(payload_hash)

      cached = @cache_mutex.synchronize { @cache[[fingerprint, digest]] }
      return cached if cached

      result = verify(payload_hash, store, fingerprint)
      @cache_mutex.synchronize do
        @cache.shift while @cache.size >= MAX_CACHE
        @cache[[fingerprint, digest]] = result
      end
      result
    end

    # Raised only by a broken trust store; callers treat it as "cannot confirm".
    def trust_store
      return @store if @store

      dir = trust_dir
      @store = File.directory?(dir) ? Runes::Security::TrustStore.load_dir(dir) : Runes::Security::TrustStore.new
    rescue StandardError => e
      Rails.logger.warn("[observer] trust store unreadable (#{e.class}: #{e.message}); " \
                        "every signed packet will read as untrusted")
      Runes::Security::TrustStore.new
    end

    def trust_dir
      ENV["RUNES_OBSERVER_TRUST_DIR"].presence ||
        ENV["RUNES_TRUST_DIR"].presence ||
        File.join(harness_root, "config", "trust")
    end

    def harness_root
      lib = ENV.fetch("RUNES_HARNESS_LIB") { File.expand_path("../../../lib", Rails.root) }
      File.expand_path("..", lib)
    end

    def require_signatures?
      %w[1 true yes on].include?(ENV["RUNES_OBSERVER_REQUIRE_SIGNATURES"].to_s.strip.downcase)
    end

    # Tests (and a long-lived process with a rotated trust store) need to drop
    # the memo and re-read the directory.
    def reset_cache!
      @cache_mutex.synchronize { @cache.clear }
      @store = nil
      true
    end

    def cache_size
      @cache_mutex.synchronize { @cache.size }
    end

    private

    def signed?(payload_hash)
      Runes::Security::Envelope.signed?(payload_hash)
    rescue StandardError
      false
    end

    def unsigned(payload_hash)
      Result.new(state: "unsigned", claimed_agent: claimed_agent(payload_hash), fingerprint: nil, reason: nil)
    end

    def verify(payload_hash, store, fingerprint)
      claimed = claimed_agent(payload_hash)
      Runes::Security::Envelope.verify!(payload_hash, store)
      Result.new(state: "verified", fingerprint: fingerprint, claimed_agent: claimed, reason: nil)
    rescue Runes::Security::VerificationError => e
      Result.new(state: UNTRUSTED_REASONS.include?(e.reason) ? "untrusted" : "invalid",
                 fingerprint: fingerprint, claimed_agent: claimed, reason: e.reason)
    rescue StandardError => e
      # A bug in the verifier must never read as trust.
      Rails.logger.warn("[observer] signature check failed: #{e.class}: #{e.message}")
      Result.new(state: "invalid", fingerprint: fingerprint, claimed_agent: claimed, reason: e.class.name)
    end

    # Which agent the envelope claims to be. `agent` is what the dispatcher
    # writes; `from` is what a delegation envelope carries.
    def claimed_agent(payload_hash)
      return nil unless payload_hash.is_a?(Hash)

      (payload_hash["agent"] || payload_hash["from"]).to_s.presence
    end

    # The digest covers the signed payload without its signature fields, so two
    # different signers of the same content cannot collide in the memo.
    def digest_of(payload_hash)
      canonical = Runes::Security::Envelope.canonical(
        Runes::Security::Envelope.strip_signature(payload_hash)
      )
      Digest::SHA256.hexdigest(canonical)
    rescue StandardError
      # Uncanonicalisable (Float, Array, …): not memoizable, and verify! will
      # reject it as malformed anyway.
      Digest::SHA256.hexdigest(payload_hash.to_s)
    end
  end
end
