require "json"
require "securerandom"

module Runes
  # Agent-to-agent interoperability, following the A2A-over-MQTT profile:
  # agents publish a retained Agent Card on a standard discovery topic,
  # presence rides on an `a2a-status` MQTT 5 user property, and tasks are
  # correlated with Response Topic / Correlation Data.
  #
  # Runes keeps its legacy `runes/agents/...` topics as well (the TUI and
  # the observatory rely on them); A2A is the interoperable surface.
  module A2A
    DISCOVERY_PREFIX = "$a2a/v1/discovery".freeze
    TASK_PREFIX      = "$a2a/v1/tasks".freeze
    STATUS_PROPERTY  = "a2a-status".freeze

    module_function

    def discovery_topic(org:, unit:, agent_id:)
      "#{DISCOVERY_PREFIX}/#{segment(org)}/#{segment(unit)}/#{segment(agent_id)}"
    end

    # Everything discovered for one org. The DEFAULT is the wildcard itself,
    # so it must not go through #segment — `segment("+")` is "-", which
    # produced a filter that matched nothing (doc5.md T5-13).
    def discovery_wildcard(org = "+")
      "#{DISCOVERY_PREFIX}/#{segment_or_wildcard(org)}/+/+"
    end

    # Addressed task topic for one agent (Runes' own addressed channel is
    # kept separately; this is the profile-friendly one).
    def task_topic(org:, unit:, agent_id:)
      "#{TASK_PREFIX}/#{segment(org)}/#{segment(unit)}/#{segment(agent_id)}"
    end

    def task_wildcard(org = "+", unit = "+")
      "#{TASK_PREFIX}/#{segment_or_wildcard(org)}/#{segment_or_wildcard(unit)}/+"
    end

    def discovery?(topic)
      topic.to_s.start_with?("#{DISCOVERY_PREFIX}/")
    end

    def task?(topic)
      topic.to_s.start_with?("#{TASK_PREFIX}/")
    end

    def agent_id_from_discovery(topic)
      parts = topic.to_s.split("/")
      # $a2a / v1 / discovery / <org> / <unit> / <agent_id>
      parts[5] if discovery?(topic) && parts.size >= 6
    end

    def status_properties(state)
      { STATUS_PROPERTY => state.to_s }
    end

    def status_from(properties)
      props = properties.respond_to?(:dig) ? properties.dig(:user_properties) : nil
      props && props[STATUS_PROPERTY]
    end

    # A caller-supplied wildcard stays a wildcard; anything else is made
    # safe for an MQTT topic name.
    def segment_or_wildcard(value)
      value.to_s.strip == "+" ? "+" : segment(value)
    end

    # A topic segment: keep it safe for MQTT topic names.
    def segment(value)
      cleaned = value.to_s.strip.gsub(/[^A-Za-z0-9_.-]/, "-")
      cleaned.empty? ? "default" : cleaned
    end
  end
end

require_relative "a2a/card"
require_relative "a2a/task"
