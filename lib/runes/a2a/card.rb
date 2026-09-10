require "json"

module Runes
  module A2A
    # Builds and parses A2A Agent Cards.
    #
    # The card keeps A2A's field names (`protocolVersion`, `skills`,
    # `capabilities`, `preferredTransport`, …) so any A2A client can read
    # it, and carries Runes-specific facts under the `x-runes` extension
    # rather than inventing top-level fields.
    module Card
      PROTOCOL_VERSION = "0.3.0".freeze
      REQUIRED = %w[name version].freeze

      module_function

      def build(agent_id:, name: nil, description: nil, version: nil, url: nil,
                skills: [], capabilities: {}, provider: nil, extra: {})
        {
          "protocolVersion" => PROTOCOL_VERSION,
          "name" => (name || agent_id),
          "description" => description,
          "url" => url,
          "preferredTransport" => "MQTT",
          "version" => version,
          "capabilities" => capabilities.empty? ? { "streaming" => true, "pushNotifications" => false } : capabilities,
          "defaultInputModes" => ["text/plain"],
          "defaultOutputModes" => ["text/plain"],
          "skills" => skills,
          "provider" => provider,
          "x-runes" => extra
        }.compact
      end

      def skill(id:, name: nil, description: nil, tags: [], examples: [])
        {
          "id" => id,
          "name" => (name || id),
          "description" => description,
          "tags" => tags,
          "examples" => examples
        }.compact
      end

      # One skill per tool: the planner-visible surface of an agent.
      def skills_from_tools(tool_names, registry_cards = {})
        Array(tool_names).uniq.map do |tool|
          card = registry_cards[tool] || {}
          skill(
            id: tool,
            name: tool,
            description: card["description"] || "Runs the #{tool} tool",
            tags: ["tool"]
          )
        end
      end

      def parse(payload)
        data = payload.is_a?(String) ? JSON.parse(payload) : payload
        return nil unless data.is_a?(Hash)
        return nil unless REQUIRED.all? { |field| data[field].to_s.strip.length.positive? }

        data
      rescue JSON::ParserError
        nil
      end

      def name_of(card)
        card.is_a?(Hash) ? card["name"].to_s : ""
      end

      def skills_of(card)
        card.is_a?(Hash) ? Array(card["skills"]) : []
      end

      def runes_extension(card)
        card.is_a?(Hash) ? (card["x-runes"] || {}) : {}
      end
    end
  end
end
