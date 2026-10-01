# frozen_string_literal: true

require_relative 'crypto_backend'
require_relative 'ed25519_der'
require_relative '../compat'
require_relative '../sha256_facade'

module Runes
  module Security
    # Raised for any key-management failure (unreadable, malformed, not an
    # Ed25519 private key, unsafe agent id). Identity is FAIL CLOSED: it
    # never silently generates a replacement for a key file it could not
    # parse — that would make an agent silently unverifiable.
    class IdentityError < StandardError; end

    # Per-agent Ed25519 keypair.
    #
    #   id = Runes::Security::Identity.load_or_create(agent_id: 'runes-a')
    #   id.fingerprint            # => full SHA-256 hex of the DER public key
    #   id.sign(canonical_bytes)  # => 64-byte signature
    #
    # Private keys live at `<project>/config/keys/<agent_id>.pem` mode 0600
    # (overridable with RUNES_AGENT_KEY for containers/secret stores).
    # The private key is NEVER logged or printed: #inspect redacts it and no
    # error message embeds key material.
    #
    # Key material is raw 32-byte strings at the boundary; PKCS#8/SPKI
    # DER+PEM encoding goes through Runes::Security::Ed25519Der (pure
    # subset), and signing/derivation through the CryptoBackend seam — so
    # this file compiles under Spinel with no OpenSSL anywhere.
    class Identity
      ALGORITHM = 'ed25519'
      DEFAULT_KEY_ENV = 'RUNES_AGENT_KEY'
      # Agent ids become filenames and MQTT topic fragments; keep them to a
      # conservative, path-free alphabet.
      AGENT_ID_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
      SHORT_FINGERPRINT_HEX = 16

      class << self
        # Directory that generated keys live in. Honours RUNES_ROOT the
        # same way Settings does so tests/embeds never write into the
        # developer's checkout.
        def default_dir
          root = ENV['RUNES_ROOT'].to_s
          root = File.expand_path('../../..', __dir__) if root.empty?
          File.join(root, 'config', 'keys')
        end

        # Load an agent key, generating one on first use.
        #
        # Precedence (deterministic, documented, and fail-closed):
        #   1. +key_env+ holds a PEM private key (or a path to one)
        #   2. <dir>/<agent_id>.pem exists
        #   3. generate a new Ed25519 keypair and persist it 0600
        #
        # @param agent_id [String] non-empty id matching AGENT_ID_RE
        # @param dir [String, nil] key directory (default default_dir)
        # @param key_env [String] environment variable holding a PEM key
        # @return [Runes::Security::Identity]
        def load_or_create(agent_id:, dir: nil, key_env: DEFAULT_KEY_ENV)
          id = normalize_agent_id(agent_id)

          env_value = ENV[key_env].to_s
          unless env_value.strip.empty?
            pem = if env_value.include?('-----BEGIN')
                    env_value
                  elsif File.file?(env_value)
                    read_file!(env_value)
                  else
                    raise IdentityError,
                          "identity: #{key_env} does not hold a PEM private key or a readable file path"
                  end
            return from_pem(id, pem, source: key_env)
          end

          directory = dir || default_dir
          path = File.join(directory, "#{id}.pem")
          return from_pem(id, read_file!(path), source: path) if File.exist?(path)

          identity = generate(id)
          write_key!(identity, path)
          identity
        end

        # Build an Identity from a PEM private key string.
        def from_pem(agent_id, pem, source: 'memory')
          id = normalize_agent_id(agent_id)
          seed = parse_private_pem(pem, id, source)
          new(id, seed)
        end

        # Generate a fresh in-memory Ed25519 identity (no file writes).
        def generate(agent_id)
          id = normalize_agent_id(agent_id)
          pair = begin
            CryptoBackend.generate_keypair
          rescue CryptoBackend::UnavailableError => e
            raise IdentityError, "identity: Ed25519 key generation failed: #{e.message}"
          end
          new(id, pair[:seed])
        end

        # SHA-256 hex of the DER-encoded public key — the stable key id and
        # the value signed into envelopes as `kid`.
        def fingerprint_of(public_key_pem)
          raw = public_raw(public_key_pem)
          Runes::SHA256.hex(Ed25519Der.public_spki_der(raw))
        rescue Ed25519Der::DerError => e
          raise IdentityError, "identity: cannot fingerprint public key: #{e.message}"
        end

        def ed25519_oid_name
          ALGORITHM.upcase
        end

        # Parse a PEM into a raw public key (private PEMs reduced to their
        # public half). Used by TrustStore and deploy tooling.
        def public_raw(pem)
          parsed = Ed25519Der.parse_pem(pem)
          parsed[:kind] == :private ? CryptoBackend.public_from_private(parsed[:seed]) : parsed[:raw]
        rescue Ed25519Der::DerError => e
          raise e
        rescue CryptoBackend::UnavailableError => e
          raise IdentityError, "identity: cannot derive public key: #{e.message}"
        end

        private

        def parse_private_pem(pem, id, source)
          parsed = Ed25519Der.parse_pem(pem)
          unless parsed[:kind] == :private
            raise IdentityError, "identity: #{source} for #{id} is not a private key (fail closed)"
          end

          parsed[:seed]
        rescue Ed25519Der::DerError => e
          message = e.message
          if message.include?('expected Ed25519')
            raise IdentityError,
                  "identity: #{source} for #{id} is not #{ed25519_oid_name} (#{message})"
          end

          raise IdentityError, "identity: malformed private key for #{id} (#{source}): #{message}"
        end

        def normalize_agent_id(agent_id)
          id = agent_id.to_s
          return id if id.match?(AGENT_ID_RE)

          raise IdentityError,
                "identity: invalid agent id #{agent_id.inspect} (expected #{AGENT_ID_RE.source})"
        end

        def read_file!(path)
          data = File.read(path)
          raise IdentityError, "identity: empty key file #{path}" if data.strip.empty?

          data
        rescue Errno::ENOENT, Errno::EACCES, IOError, SystemCallError => e
          raise IdentityError, "identity: cannot read key at #{path}: #{e.class}: #{e.message}"
        end

        # Atomic write: temp file in the same directory (0600) then rename,
        # so a crash can never leave a truncated key at +path+. If another
        # process wins the race, its key is loaded instead.
        def write_key!(identity, path)
          directory = File.dirname(path)
          Runes::Compat.mkdir_p(directory)
          if File.exist?(path)
            existing = read_file!(path)
            return from_pem(identity.agent_id, existing, source: path)
          end

          tmp = File.join(directory, ".#{identity.agent_id}.pem.#{Runes::Random.hex(6)}")
          begin
            File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
              f.write(identity.private_key_pem)
              f.flush
              f.fsync
            end
            File.chmod(0o600, tmp)
            File.rename(tmp, path)
          rescue Errno::EEXIST
            # Lost a generation race: prefer the winner's key.
            return from_pem(identity.agent_id, read_file!(path), source: path)
          ensure
            File.delete(tmp) if File.exist?(tmp)
          end
          File.chmod(0o600, path)
          identity
        rescue SystemCallError => e
          raise IdentityError, "identity: cannot write key at #{path}: #{e.class}: #{e.message}"
        end
      end

      attr_reader :agent_id

      def initialize(agent_id, seed)
        @agent_id = agent_id.to_s
        @seed = seed.to_s
        raise IdentityError, "identity: bad private key material for #{@agent_id}" unless @seed.bytesize == 32
      end

      # PEM-encoded public key (safe to publish / write to a TrustStore).
      def public_key_pem
        @public_key_pem ||= Ed25519Der.public_pem(raw_public_key)
      end

      # PEM-encoded private key. Callers must treat this as a secret: never
      # log it, never put it in a message or an Agent Card.
      def private_key_pem
        @private_key_pem ||= Ed25519Der.private_pem(@seed)
      end

      # Full SHA-256 hex of the DER public key — the envelope `kid` and the
      # trust-store lookup key.
      def fingerprint
        @fingerprint ||= Runes::SHA256.hex(Ed25519Der.public_spki_der(raw_public_key))
      end

      # Truncated fingerprint for logs and human display only.
      def short_fingerprint(length = SHORT_FINGERPRINT_HEX)
        fingerprint[0, Integer(length)]
      end
      alias display_fingerprint short_fingerprint
      alias kid fingerprint

      # Ed25519 signs the raw bytes (no pre-hash): pass canonical form.
      def sign(bytes)
        CryptoBackend.sign(bytes, @seed)
      rescue CryptoBackend::UnavailableError => e
        raise IdentityError, "identity: signing unavailable: #{e.message}"
      end

      # @return [Boolean] true only when the signature is valid for bytes
      def verify(bytes, signature)
        return false if signature.nil?

        CryptoBackend.verify(signature.to_s, bytes.to_s, raw_public_key)
      end

      # Never expose key material through logs, errors or `p`/`puts`.
      def inspect
        "#<Runes::Security::Identity agent_id=#{@agent_id} " \
          "alg=#{ALGORITHM} fingerprint=#{short_fingerprint} key=[REDACTED]>"
      end

      def to_s
        inspect
      end

      private

      def raw_public_key
        @raw_public_key ||= begin
          CryptoBackend.public_from_private(@seed)
        rescue CryptoBackend::UnavailableError => e
          raise IdentityError, "identity: public derivation unavailable: #{e.message}"
        end
      end
    end
  end
end
