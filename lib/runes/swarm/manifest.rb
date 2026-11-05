# frozen_string_literal: true

require_relative '../json_facade'
require_relative 'identity'
require_relative 'capacity'
require_relative 'model_family'

module Runes
  module Swarm
    # One role's declared contract, loaded from `config/agents/*.json`.
    #
    # The manifest is data: identity, positive/negative capacities, token
    # bounds, output schema and forbidden actions. The registry, not a model,
    # is the source of identity.
    class Manifest
      class Invalid < ArgumentError; end

      DETERMINISTIC_ROLES = ModelFamily::DETERMINISTIC_ROLES
      ESCALATION_ROLE = :escalation

      IDENTITY_FIELDS = Identity::FIELDS
      FIELDS = (IDENTITY_FIELDS + %w[capacities requires_evidence forbidden_actions]).freeze

      attr_reader :identity, :capacity, :forbidden_actions, :path

      def self.load(path)
        text = File.read(path)
        data = Runes::Json.parse(text)
        new(data, path: path)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Invalid, "manifest: cannot read #{path}: #{e.message}"
      rescue Runes::Json::ParseError => e
        raise Invalid, "manifest: #{path} is not valid JSON: #{e.message}"
      end

      # Load every `*.json` in a directory, sorted by path. A duplicate
      # agent_id is a directory-level error: two files must never claim the
      # same identity.
      def self.load_all(dir)
        paths = Dir.glob(File.join(dir.to_s, '*.json')).sort
        manifests = paths.map { |path| load(path) }

        duplicate = manifests.group_by(&:agent_id).find { |_id, group| group.size > 1 }
        if duplicate
          raise Invalid, "manifest: duplicate agent_id #{duplicate[0].inspect} in #{dir}"
        end

        manifests
      end

      def self.from_h(hash, path: nil)
        new(hash, path: path)
      end

      def initialize(data, path: nil)
        @path = path&.to_s
        fields = normalize(data)

        unknown = fields.keys - FIELDS
        raise Invalid, "manifest#{suffix}: unknown keys #{unknown.sort.inspect}" unless unknown.empty?

        missing = FIELDS - fields.keys
        raise Invalid, "manifest#{suffix}: missing keys #{missing.sort.inspect}" unless missing.empty?

        @identity = Identity.from_h(identity_data(fields))
        @capacity = Capacity.from_h(fields.fetch('capacities'))
        @forbidden_actions = forbidden_actions!(fields.fetch('forbidden_actions'))
        @requires_evidence = requires_evidence!(fields.fetch('requires_evidence'))

        validate!
        freeze
      rescue Identity::Invalid, Capacity::Invalid => e
        raise Invalid, "manifest#{suffix}: #{e.message}"
      end

      def agent_id
        identity.agent_id
      end

      def version
        identity.version
      end

      def role
        identity.role
      end

      def base_model
        identity.base_model
      end

      def adapter
        identity.adapter
      end

      def adapter_sha256
        identity.adapter_sha256
      end

      def family
        ModelFamily.fetch(base_model)
      end

      def requires_evidence?
        @requires_evidence
      end

      def deterministic?
        DETERMINISTIC_ROLES.include?(role)
      end

      def to_h
        identity.to_h.merge(
          'capacities' => capacity.to_h,
          'requires_evidence' => requires_evidence?,
          'forbidden_actions' => forbidden_actions.map(&:to_s)
        )
      end

      def ==(other)
        other.is_a?(Manifest) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def inspect
        "#<#{self.class.name} #{agent_id}@#{version} role=#{role} path=#{path.inspect}>"
      end

      private

      def normalize(data)
        raise Invalid, "manifest#{suffix}: expected a Hash, got #{data.class}" unless data.is_a?(Hash)

        data.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def identity_data(fields)
        IDENTITY_FIELDS.each_with_object({}) { |key, out| out[key] = fields[key] }
      end

      def forbidden_actions!(value)
        unless value.is_a?(Array)
          raise Invalid, "manifest#{suffix}: forbidden_actions must be an Array"
        end

        value.map do |action|
          unless action.is_a?(Symbol) || action.is_a?(String)
            raise Invalid, "manifest#{suffix}: forbidden_actions entries must be Symbols or Strings"
          end

          action.to_sym
        end.uniq.freeze
      end

      def requires_evidence!(value)
        return value if [true, false].include?(value)

        raise Invalid, "manifest#{suffix}: requires_evidence must be true or false"
      end

      def validate!
        validate_base_model!
        validate_adapter_substrate!
        validate_output_schema!
        validate_context_window!

        outside = forbidden_actions - capacity.cannot
        unless outside.empty?
          raise Invalid,
                "manifest#{suffix}: forbidden_actions outside cannot: #{outside.inspect}"
        end

        validate_token_budget!
      end

      def validate_base_model!
        models = ModelFamily.models_for(role)
        return if models.include?(base_model)

        expected = models.size == 1 ? models.first.inspect : "one of #{models.inspect}"
        raise Invalid,
              "manifest#{suffix}: role #{role} requires base_model #{expected}, got #{base_model.inspect}"
      rescue ModelFamily::Invalid => e
        raise Invalid, "manifest#{suffix}: #{e.message}"
      end

      # The Base checkpoint is an adapter substrate, not a runtime role. A
      # manifest may name it only when it also names the adapter it runs.
      def validate_adapter_substrate!
        return unless base_model == 'LiquidAI/LFM3-1.7B-Base'
        return unless adapter_sha256.nil?

        raise Invalid,
              "manifest#{suffix}: the Base model requires a non-nil adapter_sha256"
      end

      def validate_output_schema!
        expected = ModelFamily.schema_for(role)
        return if capacity.output_schema == expected

        raise Invalid,
              "manifest#{suffix}: role #{role} requires output_schema #{expected.inspect}, " \
              "got #{capacity.output_schema.inspect}"
      rescue ModelFamily::Invalid => e
        raise Invalid, "manifest#{suffix}: #{e.message}"
      end

      def validate_context_window!
        limit = family.context_tokens
        return if capacity.max_input_tokens <= limit

        raise Invalid,
              "manifest#{suffix}: max_input_tokens #{capacity.max_input_tokens} exceeds " \
              "#{base_model} context #{limit}"
      rescue ModelFamily::Invalid => e
        raise Invalid, "manifest#{suffix}: #{e.message}"
      end

      def validate_token_budget!
        if deterministic? || !family.generates_tokens?
          unless capacity.max_output_tokens.zero?
            raise Invalid,
                  "manifest#{suffix}: role #{role} must use max_output_tokens: 0"
          end
        elsif !capacity.max_output_tokens.positive?
          raise Invalid,
                "manifest#{suffix}: model-backed role #{role} requires max_output_tokens > 0"
        end
      end

      def suffix
        path.nil? ? '' : " #{path}"
      end
    end
  end
end
