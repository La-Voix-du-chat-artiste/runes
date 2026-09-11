# Maps a Runes MQTT topic (+ payload) onto the columns the observer stores.
#
# Pure and side-effect free, so the whole topic grammar is cheap to unit
# test. Runes topics (see the runes README "MQTT Topic Map"):
#
#   runes/agents/<id>/card|status|tasks
#   runes/agents/<id>/tasks/<req>/response
#   runes/prompts                       (broadcast envelope)
#   runes/prompts/<req>/progress|response
#   runes/prompts/response              (global fan-out summary)
#   runes/tools/<tool>/request|response|error
#   runes/_log/prompts                  (journal entry; carries the agent)
#   runes/guard/denied                  (capability refusal; who/what/on-what)
#
# Phase 16 deleted the claim/lease protocol, so there is no
# `runes/prompts/<req>/claim|started` and no `runes/sessions/…` vocabulary.
#
# A2A-over-MQTT topics (see lib/runes/a2a.rb):
#
#   $a2a/v1/discovery/<org>/<unit>/<agent_id>   (retained Agent Card)
#   $a2a/v1/tasks/<org>/<unit>/<agent_id>       (addressed task)
module PacketClassifier
  # The vocabulary a classified topic can produce. It lives HERE, in the pure
  # module, rather than only on the ActiveRecord model, so the parent suite can
  # assert that every topic the harness publishes maps into it (doc5.md E5-2):
  # the two halves of the contract are then checked against one list instead of
  # two copies that drift.
  KINDS = %w[
    card status task task_response a2a_card a2a_task
    prompt progress response response_global
    tool_request tool_response tool_error
    journal workflow_event guard_denied other
  ].freeze

  Result = Struct.new(:kind, :agent_id, :request_id, :event, :tool, :run_id,
                      keyword_init: true)

  AGENT_CARD        = %r{\Arunes/agents/([^/]+)/card\z}
  AGENT_STATUS      = %r{\Arunes/agents/([^/]+)/status\z}
  TASK_REPLY        = %r{\Arunes/agents/([^/]+)/tasks/([^/]+)/response\z}
  AGENT_TASKS       = %r{\Arunes/agents/([^/]+)/tasks\z}
  PROMPT            = "runes/prompts"
  GLOBAL_RESPONSE   = "runes/prompts/response"
  PROMPT_PROGRESS   = %r{\Arunes/prompts/([^/]+)/progress\z}
  PROMPT_RESPONSE   = %r{\Arunes/prompts/([^/]+)/response\z}
  TOOL              = %r{\Arunes/tools/([^/]+)/(request|response|error)\z}
  # A capability refusal published by the guard (doc5.md O2.3): the topic is
  # fixed and the payload carries who/what/on-what.
  GUARD             = %r{\Arunes/guard/denied\z}
  JOURNAL           = %r{\Arunes/_log/prompts(?:/latest)?\z}

  # Workflow telemetry: runes/workflows/<run_id>/<run_started|step_started|
  # step_finished|run_finished>. Emitted by the engine's telemetry sink
  # (lib/runes/telemetry.rb) and projected into WorkflowRun/WorkflowStep.
  WORKFLOW          = %r{\Arunes/workflows/([^/]+)/([a-z_]+)\z}

  # A2A-over-MQTT. The whole topic must match: a topic that merely starts
  # with `$a2a` but is missing `<org>/<unit>/<agent_id>` falls through to
  # `other` instead of raising or half-matching.
  A2A_CARD          = %r{\A\$a2a/v1/discovery/([^/]+)/([^/]+)/([^/]+)\z}
  A2A_TASK          = %r{\A\$a2a/v1/tasks/([^/]+)/([^/]+)/([^/]+)\z}

  module_function

  def call(topic:, payload:)
    data = parse(payload)
    topic = topic.to_s

    case topic
    when AGENT_CARD
      Result.new(kind: "card", agent_id: $1)
    when AGENT_STATUS
      Result.new(kind: "status", agent_id: $1)
    when TASK_REPLY
      Result.new(kind: "task_response", agent_id: $1, request_id: $2)
    when AGENT_TASKS
      # A delegation envelope: topic segment is the peer that will execute,
      # `from` is the delegator, `request_id` correlates the whole task.
      Result.new(kind: "task", agent_id: $1, request_id: dig(data, "request_id"))
    when GLOBAL_RESPONSE
      Result.new(kind: "response_global", agent_id: envelope_agent(data))
    when PROMPT
      Result.new(kind: "prompt", request_id: dig(data, "request_id"),
                 agent_id: envelope_agent(data))
    when PROMPT_PROGRESS
      Result.new(kind: "progress", request_id: $1, event: dig(data, "event"),
                 agent_id: envelope_agent(data))
    when PROMPT_RESPONSE
      Result.new(kind: "response", request_id: $1, agent_id: envelope_agent(data))
    when TOOL
      Result.new(kind: "tool_#{$2}", tool: $1,
                 request_id: dig(data, "request_id"),
                 agent_id: envelope_agent(data))
    when JOURNAL
      Result.new(kind: "journal", agent_id: dig(data, "agent"),
                 request_id: dig(data, "request_id"))
    when GUARD
      # `event` is the denied action, `tool` the tool or rune that asked; the
      # resource is in the payload and shown in the headline.
      Result.new(kind: "guard_denied", tool: dig(data, "tool"),
                 agent_id: dig(data, "agent"), event: dig(data, "action"))
    when WORKFLOW
      Result.new(kind: "workflow_event", run_id: $1, event: $2)
    when A2A_CARD
      Result.new(kind: "a2a_card", agent_id: $3)
    when A2A_TASK
      Result.new(kind: "a2a_task", agent_id: $3,
                 request_id: dig(data, "request_id") || dig(data, "taskId"))
    else
      Result.new(kind: "other")
    end
  end

  def parse(payload)
    text = payload.to_s
    return nil if text.empty?

    parsed = JSON.parse(text)
    parsed.is_a?(Hash) ? normalize_card(parsed) : nil
  rescue JSON::ParserError
    nil
  end

  # A2A Agent Cards keep A2A's own field names at the top level and put the
  # Runes-specific facts under `x-runes`. The observer's Agent row reads
  # `kind` / `workspace` / `tools` from the top level (the legacy card
  # shape), so lift the extension's keys up for both shapes. `data` wins on
  # a key collision, and `x-runes` itself is left in place.
  def normalize_card(data)
    return data unless data.is_a?(Hash)

    extension = data["x-runes"]
    return data unless extension.is_a?(Hash)

    extension.merge(data)
  end

  # An envelope may name its executor directly (`agent`, e.g. the journal
  # entry) or name its sender (`from`, e.g. a delegation envelope).
  def envelope_agent(data)
    dig(data, "agent") || dig(data, "from")
  end

  def dig(data, key)
    return nil unless data.is_a?(Hash)

    value = data[key]
    value.to_s.strip.empty? ? nil : value.to_s
  end
end
