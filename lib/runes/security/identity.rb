# frozen_string_literal: true

require 'openssl'
require 'digest'
require 'fileutils'

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
          key = begin
            OpenSSL::PKey.read(pem.to_s)
          rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError => e
            raise IdentityError, "identity: malformed private key for #{id} (#{source}): #{e.class}"
          end

          unless private_key?(key)
            raise IdentityError, "identity: #{source} for #{id} is not a private key (fail closed)"
          end
          unless ed25519?(key)
            raise IdentityError,
                  "identity: #{source} for #{id} is #{key.oid} (expected #{ALGORITHM.upcase})"
          end

          new(id, key)
        end

        # Generate a fresh in-memory Ed25519 identity (no file writes).
        def generate(agent_id)
          new(normalize_agent_id(agent_id), OpenSSL::PKey.generate_key('ED25519'))
        rescue OpenSSL::PKey::PKeyError => e
          raise IdentityError, "identity: Ed25519 key generation failed: #{e.message}"
        end

        # SHA-256 hex of the DER-encoded public key — the stable key id and
        # the value signed into envelopes as `kid`.
        def fingerprint_of(public_key_pem)
          key = OpenSSL::PKey.read(public_key_pem.to_s)
          Digest::SHA256.hexdigest(key.public_to_der)
        rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError => e
          raise IdentityError, "identity: cannot fingerprint public key: #{e.class}"
        end

        def ed25519?(key)
          key.respond_to?(:oid) && key.oid.to_s.upcase == ALGORITHM.upcase
        end

        # `OpenSSL::PKey::PKey#private_key?` does not exist for Ed25519 in
        # the openssl gem; a public-only key fails #private_to_pem instead.
        def private_key?(key)
          if key.respond_to?(:private_key?)
            key.private_key?
          else
            key.private_to_pem
            true
          end
        rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError
          false
        end

        private

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
          FileUtils.mkdir_p(directory, mode: 0o700)
          if File.exist?(path)
            existing = read_file!(path)
            return from_pem(identity.agent_id, existing, source: path)
          end

          tmp = File.join(directory, ".#{identity.agent_id}.pem.#{Process.pid}.#{rand(1 << 32).to_s(16)}")
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

      attr_reader :agent_id, :private_key

      def initialize(agent_id, private_key)
        @agent_id = agent_id.to_s
        @private_key = private_key
      end

      # PEM-encoded public key (safe to publish / write to a TrustStore).
      def public_key_pem
        @public_key_pem ||= @private_key.public_to_pem
      end

      # PEM-encoded private key. Callers must treat this as a secret: never
      # log it, never put it in a message or an Agent Card.
      def private_key_pem
        @private_key_pem ||= @private_key.private_to_pem
      end

      # Full SHA-256 hex of the DER public key — the envelope `kid` and the
      # trust-store lookup key.
      def fingerprint
        @fingerprint ||= Digest::SHA256.hexdigest(@private_key.public_to_der)
      end

      # Truncated fingerprint for logs and human display only.
      def short_fingerprint(length = SHORT_FINGERPRINT_HEX)
        fingerprint[0, Integer(length)]
      end
      alias display_fingerprint short_fingerprint
      alias kid fingerprint

      # Ed25519 signs the raw bytes (no pre-hash): pass canonical form.
      def sign(bytes)
        @private_key.sign(nil, bytes.to_s)
      end

      # @return [Boolean] true only when the signature is valid for bytes
      def verify(bytes, signature)
        return false if signature.nil?

        @private_key.verify(nil, signature.to_s, bytes.to_s)
      rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError
        false
      end

      # Never expose key material through logs, errors or `p`/`puts`.
      def inspect
        "#<Runes::Security::Identity agent_id=#{@agent_id} " \
          "alg=#{ALGORITHM} fingerprint=#{short_fingerprint} key=[REDACTED]>"
      end

      def to_s
        inspect
      end
    end
  end
end
