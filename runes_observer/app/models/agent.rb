# A participant observed on the Runes MQTT fabric.
#
# Rows are created/updated from `runes/agents/<id>/card` (metadata) and
# `runes/agents/<id>/status` (online/offline, incl. the broker's Last Will)
# and are "touched" whenever another packet is attributed to the agent.
#
# State is driven ONLY by the status topic: a retained card is re-delivered
# to every new subscriber, so a card must never flip an agent to online.
class Agent < ApplicationRecord
  STATES = %w[online offline unknown].freeze

  # An agent that said `online` but has been silent for this long is shown
  # as stale rather than running (crashed without a clean LWT, network cut).
  STALE_AFTER = 5.minutes

  validates :agent_id, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }

  scope :online, -> { where(state: "online") }
  scope :ended, -> { where(state: "offline") }
  scope :by_activity, -> { order(last_seen_at: :desc) }
  scope :search, lambda { |q|
    next all if q.blank?

    pattern = "%#{sanitize_sql_like(q.to_s)}%"
    where("agent_id LIKE :q ESCAPE '\\' OR name LIKE :q ESCAPE '\\' OR workspace LIKE :q ESCAPE '\\'",
          q: pattern)
  }

  # --- ingestion hooks -------------------------------------------------

  # Metadata from a retained/live Agent Card. Never changes state. A retained
  # replay (`touch: false`) must not advance last_seen_at: the broker
  # re-delivers the card to every new subscriber, and a card that refreshes a
  # dead agent's clock would keep it looking alive forever.
  def self.record_card!(agent_id, card, at: Time.current, touch: true)
    agent = find_or_initialize_by(agent_id: agent_id)
    agent.first_seen_at ||= at
    agent.last_seen_at ||= at
    agent.last_seen_at = at if touch
    agent.name = card["name"] if card["name"].present?
    agent.kind = card["kind"] if card["kind"].present?
    agent.version = card["version"] if card["version"].present?
    agent.workspace = card["workspace"] if card["workspace"].present?
    agent.tools = Array(card["tools"]).to_json if card.key?("tools")
    agent.card = card.to_json
    agent.save!
    agent
  end

  # online / offline from `runes/agents/<id>/status` (LWT publishes offline).
  # A retained replay (`touch: false`) still records the state but leaves the
  # clock alone, so a retained `online` cannot outlive the stale check.
  def self.record_status!(agent_id, status, at: Time.current, touch: true)
    agent = find_or_initialize_by(agent_id: agent_id)
    agent.first_seen_at ||= at
    agent.last_seen_at ||= at
    agent.last_seen_at = at if touch
    case status.to_s.strip.downcase
    when "online"
      agent.state = "online"
      agent.ended_at = nil
    when "offline"
      agent.state = "offline"
      agent.ended_at ||= at
    end
    agent.save!
    agent
  end

  # Any other packet attributed to this agent keeps its "last seen" fresh.
  def self.touch_seen!(agent_id, at: Time.current)
    agent = find_or_initialize_by(agent_id: agent_id)
    agent.first_seen_at ||= at
    agent.last_seen_at = at
    agent.save!
    agent
  end

  # The attributed-packet counter is maintained by PacketRecorder (the only
  # write path) so it counts card/status rows too and stays correct when
  # attribution is backfilled.
  def self.bump_packet_count!(agent_id, by: 1)
    agent = find_by(agent_id: agent_id)
    return nil unless agent

    agent.update_columns(packet_count: agent.packet_count.to_i + by.to_i)
    agent
  end

  # --- presentation ----------------------------------------------------

  # URLs address agents by their fabric id, not the row id:
  # /agents/runes-studio-4012
  def to_param
    agent_id
  end

  def tools_list
    parsed = tools.to_s.empty? ? [] : JSON.parse(tools)
    Array(parsed)
  rescue JSON::ParserError
    []
  end

  def card_hash
    card.to_s.empty? ? {} : JSON.parse(card)
  rescue JSON::ParserError
    {}
  end

  def pretty_card
    JSON.pretty_generate(card_hash)
  end

  def online?
    state == "online"
  end

  def ended?
    state == "offline"
  end

  # Running, but silent for longer than STALE_AFTER.
  def stale?
    online? && last_seen_at.present? && last_seen_at < STALE_AFTER.ago
  end

  # online | stale | offline | unknown — the badge the UI shows.
  def display_state
    return "stale" if stale?
    return state if STATES.include?(state)

    "unknown"
  end
end
