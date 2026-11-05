# frozen_string_literal: true

module Runes
  module Swarm
    # The identity a role is *assigned*, never one it chooses.
    #
    # The registry is the only source of truth: the conductor builds this
    # value from a manifest and compares it with the identity block the model
    # echoes back. A mismatch is a contract violation, not a warning.
    class Identity
      class Invalid < ArgumentError; end

      ROLES = %i[
        conductor planner reviewer scout triage judge vision audio omni ideator
        answerer critic repairer verifier finalizer escalation generalist
      ].freeze

      FIELDS = %w[
        agent_id version role base_model adapter adapter_sha256
      ].freeze

      AGENT_ID = /\A[a-z][a-z0-9._-]*\z/
      VERSION = /\A\d+\.\d+\.\d+\z/
      SHA256 = /\A[0-9a-f]{64}\z/

      attr_reader :agent_id, :version, :role, :base_model, :adapter, :adapter_sha256

      # Build from a string- or symbol-keyed hash, as parsed from a manifest.
      # Unknown keys are rejected so a typo cannot silently become a default.
      def self.from_h(hash)
        data = normalize(hash)
        unknown = data.keys - FIELDS
        raise Invalid, "identity: unknown keys #{unknown.sort.inspect}" unless unknown.empty?

        missing = FIELDS - data.keys - ['adapter_sha256']
        raise Invalid, "identity: missing keys #{missing.sort.inspect}" unless missing.empty?

        new(
          agent_id: data.fetch('agent_id'),
          version: data.fetch('version'),
          role: data.fetch('role'),
          base_model: data.fetch('base_model'),
          adapter: data.fetch('adapter'),
          adapter_sha256: data['adapter_sha256']
        )
      end

      def self.normalize(hash)
        raise Invalid, "identity: expected a Hash, got #{hash.class}" unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end
      private_class_method :normalize

      def initialize(agent_id:, version:, role:, base_model:, adapter:, adapter_sha256: nil)
        @agent_id = string!(agent_id, :agent_id)
        @version = string!(version, :version)
        @base_model = string!(base_model, :base_model)
        @adapter = string!(adapter, :adapter)
        @role = role.to_s.to_sym
        @adapter_sha256 = adapter_sha256.nil? ? nil : string!(adapter_sha256, :adapter_sha256)

        validate!
        freeze
      end

      def to_h
        {
          'agent_id' => agent_id,
          'version' => version,
          'role' => role.to_s,
          'base_model' => base_model,
          'adapter' => adapter,
          'adapter_sha256' => adapter_sha256
        }
      end

      def ==(other)
        other.is_a?(Identity) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def inspect
        "#<#{self.class.name} #{agent_id}@#{version} role=#{role} adapter=#{adapter}>"
      end

      private

      def validate!
        unless agent_id.match?(AGENT_ID)
          raise Invalid, "identity: invalid agent_id #{agent_id.inspect}"
        end
        unless version.match?(VERSION)
          raise Invalid, "identity: invalid version #{version.inspect} (expected MAJOR.MINOR.PATCH)"
        end
        unless ROLES.include?(role)
          raise Invalid, "identity: unknown role #{role.inspect} (known: #{ROLES.join(', ')})"
        end
        return if adapter_sha256.nil? || adapter_sha256.match?(SHA256)

        raise Invalid, "identity: adapter_sha256 must be nil or 64 lowercase hex characters"
      end

      def string!(value, field)
        unless value.is_a?(String) && !value.strip.empty?
          raise Invalid, "identity: #{field} must be a non-empty String, got #{value.inspect}"
        end

        value.dup.freeze
      end
    end
  end
end
