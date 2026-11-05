# frozen_string_literal: true

require_relative 'manifest'

module Runes
  module Swarm
    # The only source of identity: agent_id is the unique key, and a role may
    # have more than one contracted agent (two ideators, a text and an audio
    # triage, two judges).
    #
    # The conductor asks the registry for a manifest; it never constructs an
    # Identity from model output.
    class Registry
      class Error < StandardError; end
      class UnknownAgent < Error; end
      class UnknownRole < Error; end
      class DuplicateAgent < Error; end

      include Enumerable

      def initialize(manifests = [])
        @by_id = {}
        @by_role = {}
        @manifests = []
        Array(manifests).each { |manifest| register(manifest) }
      end

      def register(manifest)
        unless manifest.is_a?(Manifest)
          raise Error, "registry: expected a Manifest, got #{manifest.class}"
        end

        if @by_id.key?(manifest.agent_id)
          raise DuplicateAgent, "registry: duplicate agent_id #{manifest.agent_id.inspect}"
        end

        @by_id[manifest.agent_id] = manifest
        (@by_role[manifest.role] ||= []) << manifest
        @manifests << manifest
        manifest
      end

      def fetch(agent_id)
        @by_id[agent_id.to_s]
      end

      def fetch!(agent_id)
        fetch(agent_id) || raise(UnknownAgent, "registry: unknown agent_id #{agent_id.inspect}")
      end

      # The first agent registered for the role. Use `all_by_role` when a role
      # has more than one contracted agent and the choice matters.
      def by_role(role)
        all_by_role(role).first
      end

      def all_by_role(role)
        manifests = @by_role[role.to_s.to_sym]
        raise UnknownRole, "registry: unknown role #{role.inspect}" if manifests.nil? || manifests.empty?

        manifests.dup
      end

      def roles
        @by_role.keys.sort
      end

      def agent_ids
        @by_id.keys.sort
      end

      def manifests
        @manifests.dup
      end

      def size
        @manifests.size
      end
      alias length size

      def empty?
        @manifests.empty?
      end

      def each(&block)
        @manifests.each(&block)
      end

      def inspect
        "#<#{self.class.name} agents=#{agent_ids.inspect}>"
      end
    end
  end
end
