# frozen_string_literal: true

require_relative 'ed25519_der'
require_relative '../sha256_facade'

module Runes
  module Security
    # Raised for unreadable/malformed trust material. A store that cannot
    # parse a key is a configuration error, not a reason to weaken checks.
    class TrustStoreError < StandardError; end

    # Trusted public keys for peer verification.
    #
    #   store = Runes::Security::TrustStore.load_dir('config/trust')
    #   store.add('runes-b', peer_public_key_pem)
    #   Runes::Security::Envelope.verify!(signed_hash, store)
    #
    # Every key is indexed BOTH by agent id and by its SHA-256 fingerprint,
    # because envelopes carry the fingerprint as `kid`. Keys are held as raw
    # 32-byte Ed25519 public keys (the wire format Envelope verifies
    # against); #key_for returns those bytes. Fingerprints are computed over
    # the SPKI DER — byte-identical to the OpenSSL era, so existing `kid`
    # values keep verifying (parity-pinned by the suite).
    #
    # An EMPTY store verifies nothing (Envelope.verify! raises :unknown_key)
    # — there is no implicit trust-all. TrustStore.permissive exists for
    # tests only and never bypasses signature verification (see #trusted?).
    class TrustStore
      # Plain class (no keyword_init Struct) to stay inside the kernel subset.
      class Entry
        attr_reader :agent_id, :raw, :pem, :fingerprint

        def initialize(agent_id, raw, pem, fingerprint)
          @agent_id = agent_id
          @raw = raw
          @pem = pem
          @fingerprint = fingerprint
        end
      end

      class << self
        # Build a store from a directory of `*.pem` public keys.
        # @param dir [String]
        # @param permissive [Boolean] tests only
        def load_dir(dir, permissive: false)
          new(permissive: permissive).load_dir(dir)
        end

        # Explicit, test-only escape hatch. Keys passed here are indexed by
        # fingerprint only (no agent id). This does NOT make verification
        # succeed: an empty permissive store still fails closed.
        def permissive(*public_key_pems, paths: [])
          store = new(paths: paths, permissive: true)
          public_key_pems.flatten.each { |pem| store.add(nil, pem) }
          store
        end

        # SHA-256 hex of the SPKI DER for a PEM string or raw 32-byte key.
        def fingerprint_of(key_or_pem)
          raw = extract_raw(key_or_pem)
          Runes::SHA256.hex(Ed25519Der.public_spki_der(raw))
        rescue Ed25519Der::DerError => e
          raise TrustStoreError, "trust store: cannot fingerprint key: #{e.message}"
        end

        private

        def extract_raw(key_or_pem)
          text = key_or_pem.to_s
          return text if text.bytesize == 32

          parsed = Ed25519Der.parse_pem(text)
          parsed[:kind] == :private ? TrustStore.derive_public(parsed[:seed]) : parsed[:raw]
        end
      end

      def initialize(paths: [], permissive: false)
        @by_id = {}
        @by_fingerprint = {}
        @permissive = permissive == true
        Array(paths).each do |path|
          if File.directory?(path)
            load_dir(path)
          else
            load_file(path)
          end
        end
      end

      # Read every `*.pem` in +dir+. The filename stem is the agent id; a
      # sidecar `<stem>.id` overrides it when present (e.g. when the file
      # is named after a fingerprint or a host).
      def load_dir(dir)
        unless File.directory?(dir)
          raise TrustStoreError, "trust store: #{dir} is not a readable directory"
        end

        Dir.glob(File.join(dir, '*.pem')).sort.each { |path| load_file(path) }
        self
      end

      def load_file(path)
        pem = File.read(path)
        raise TrustStoreError, "trust store: empty public key file #{path}" if pem.strip.empty?

        add(sidecar_id(path) || File.basename(path, '.pem'), pem)
        self
      rescue Errno::ENOENT, Errno::EACCES, IOError, SystemCallError => e
        raise TrustStoreError, "trust store: cannot read #{path}: #{e.class}: #{e.message}"
      end

      # Register a trusted public key (PEM — private PEMs are reduced to
      # their public half). Pass a nil agent_id to index by fingerprint only.
      def add(agent_id, public_key_pem)
        parsed = parse_key(public_key_pem)
        raw = parsed[:kind] == :private ? TrustStore.derive_public(parsed[:seed]) : parsed[:raw]
        id = agent_id.nil? ? nil : agent_id.to_s.strip
        id = nil if id && id.empty?

        entry = Entry.new(id, raw, Ed25519Der.public_pem(raw),
                          Runes::SHA256.hex(Ed25519Der.public_spki_der(raw)))
        @by_id[id] = entry if id
        @by_fingerprint[entry.fingerprint] = entry
        entry
      end

        # @param id_or_fingerprint [String] agent id or full 64-hex fingerprint
        # @return [String, nil] the raw 32-byte Ed25519 public key
        def key_for(id_or_fingerprint)
          token = id_or_fingerprint.to_s
          return nil if token.empty?

          entry = @by_id[token] || @by_fingerprint[token]
          entry && entry.raw
        end

        # Derive a raw public key from a raw 32-byte private seed — through
        # the crypto seam (CRuby: OpenSSL; spinel: FFI).
        def self.derive_public(seed)
          require_relative 'crypto_backend'
          Runes::Security::CryptoBackend.public_from_private(seed)
        end

      # Whether the store holds a key for +agent_id+ (or, permissively,
      # anything). NOTE: permissive only relaxes this predicate — signature
      # verification still requires key_for(kid) to find a real key.
      def trusted?(agent_id)
        return true if @permissive

        !key_for(agent_id).nil?
      end

      def agent_ids
        @by_id.keys
      end

      def fingerprints
        @by_fingerprint.keys
      end

      def entry_for(id_or_fingerprint)
        token = id_or_fingerprint.to_s
        @by_id[token] || @by_fingerprint[token]
      end

      def empty?
        @by_fingerprint.empty?
      end

      def size
        @by_fingerprint.size
      end

      def permissive?
        @permissive
      end

      def inspect
        "#<Runes::Security::TrustStore keys=#{size} agents=#{agent_ids.inspect} " \
          "permissive=#{@permissive}>"
      end

      private

      def parse_key(pem)
        Ed25519Der.parse_pem(pem)
      rescue Ed25519Der::DerError => e
        message = e.message
        if message.include?('expected Ed25519')
          raise TrustStoreError,
                "trust store: unsupported public key type (expected #{IdentityAlgorithm::NAME})"
        end

        raise TrustStoreError, "trust store: malformed public key PEM"
      end

      # Name kept for error messages that used to interpolate key.oid.
      module IdentityAlgorithm
        NAME = 'ED25519'
      end

      # `<dir>/<stem>.pem` -> `<dir>/<stem>.id` contents when present.
      def sidecar_id(path)
        sidecar = path.sub(/\.pem\z/, '.id')
        return nil unless File.file?(sidecar)

        value = File.read(sidecar).strip
        value.empty? ? nil : value
      rescue SystemCallError
        nil
      end
    end
  end
end
