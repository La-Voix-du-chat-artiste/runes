# One MQTT PUBLISH observed on the fabric, classified by topic.
#
# `kind` is derived from the topic (see PacketClassifier) and
# `agent_id` / `request_id` / `event` are extracted from the topic and the
# JSON payload so the UI can group a request's whole lifecycle.
class Packet < ApplicationRecord
  # The topics the harness actually publishes (Phase 17 vocabulary). The
  # claim/lease kinds were deleted with the protocol in Phase 16.
  KINDS = %w[
    card status task task_response a2a_card a2a_task
    prompt progress response response_global
    tool_request tool_response tool_error
    journal workflow_event other
  ].freeze

  # Payloads are stored whole unless they are enormous; an observatory must
  # not be the thing that OOMs when someone publishes a 40 MB blob.
  MAX_PAYLOAD_BYTES = 256 * 1024

  # List views (feed, packet log, dashboard, agent/interaction timelines)
  # serve at most this much of a payload. The full body is one click away at
  # /packets/:id rather than 256 KiB per row per 2.5 s poll.
  SUMMARY_BYTES = 2 * 1024

  validates :topic, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(id: :desc) }
  scope :chronological, -> { order(:id) }
  scope :after_id, ->(id) { where("id > ?", id.to_i) }
  scope :before_id, ->(id) { where("id < ?", id.to_i) }
  scope :for_agent, ->(agent_id) { where(agent_id: agent_id) }
  scope :for_request, ->(request_id) { where(request_id: request_id) }
  scope :of_kind, ->(kind) { kind.present? ? where(kind: kind) : all }
  scope :since, ->(time) { time.present? ? where("occurred_at >= ?", time) : all }

  def parsed
    return @parsed if defined?(@parsed)

    @parsed = begin
      payload.to_s.empty? ? nil : JSON.parse(payload)
    rescue JSON::ParserError
      nil
    end
  end

  def pretty_payload
    parsed ? JSON.pretty_generate(parsed) : payload.to_s
  end

  # A short, human line for the feed: the most interesting field per kind.
  def headline
    data = parsed
    case kind
    when "prompt"        then data&.dig("prompt").to_s[0, 160]
    when "progress"      then [event, data&.dig("tool"), data&.dig("todo_id")].compact.join(" ")
    when "response", "response_global", "task_response", "tool_response", "tool_error"
      payload.to_s.gsub(/\s+/, " ")[0, 160]
    when "journal"       then [data&.dig("status"), data&.dig("summary")].compact.join(" — ")[0, 160]
    when "workflow_event"
      [event, data&.dig("rune"), data&.dig("name"), data&.dig("status")].compact.join(" ")[0, 160]
    when "card"          then [name_from_card(data), Array(data&.dig("tools")).join(", ")].compact.join(" — ")[0, 160]
    when "status"        then payload.to_s[0, 40]
    when "tool_request"  then payload.to_s.gsub(/\s+/, " ")[0, 160]
    else payload.to_s.gsub(/\s+/, " ")[0, 160]
    end
  end

  # The bounded version of the payload that list views render. `truncated?`
  # here means "cut for display", which is true of stored-truncated rows too.
  def summary_payload
    text = payload.to_s
    return text if text.bytesize <= SUMMARY_BYTES

    "#{text.byteslice(0, SUMMARY_BYTES).to_s.scrub}…"
  end

  def summary_truncated?
    payload.to_s.bytesize > SUMMARY_BYTES
  end

  # The grouping key used by the agent timeline.
  def correlation_key
    return "request:#{request_id}" if request_id.present?

    nil
  end

  # Roughly how long the payload is, for the "size" column.
  def size_label
    bytes = payload_bytes.to_i
    return "#{bytes} B" if bytes < 1024

    "#{(bytes / 1024.0).round(1)} KiB"
  end

  private

  def name_from_card(data)
    data&.dig("name")
  end
end
