require "time"

# Turns one observed MQTT PUBLISH into a Packet row plus the agent
# bookkeeping the UI needs. This is the single write path: live ingest and
# the demo seeder both go through it, so what the UI shows is exactly what
# the recorder stored.
class PacketRecorder
  MAX_PAYLOAD_BYTES = Packet::MAX_PAYLOAD_BYTES
  HEARTBEAT_INTERVAL = 2.0
  PRUNE_EVERY = 1_000
  EXECUTOR_CACHE_MAX = 512
  # The broker re-delivers retained messages (agent cards, `…/latest`
  # snapshots, retained status) immediately after every SUBSCRIBE. Four
  # reconnects must not store one retained card four times, so an identical
  # (topic, payload) seen inside this window after a SUBSCRIBE is treated as
  # the same retained replay and dropped.
  DEDUPE_WINDOW = 10.0
  DEFAULT_RETENTION_DAYS = 7
  DEFAULT_MAX_PACKETS = 200_000
  # User properties are publisher-controlled: bound both the number of pairs
  # and the size of each value so one hostile publisher cannot inflate the
  # database through a header field. Truncation happens per value, never on
  # the encoded JSON, so whatever is stored still parses.
  USER_PROPERTY_LIMIT = 32
  USER_PROPERTY_VALUE_BYTES = 512

  @executors = {}
  @executors_mutex = Mutex.new
  @pending_heartbeats = 0
  @pending_lag_ms = nil
  @last_heartbeat = nil
  @since_prune = 0
  @seen_digests = {}
  @dedupe_until = 0.0
  @dedupe_mutex = Mutex.new

  class << self
    def record(topic:, payload:, occurred_at: nil, received_at: Time.current, retained: false,
               qos: nil, properties: nil)
      return nil if retained_replay?(topic, payload)

      new(topic: topic, payload: payload, occurred_at: occurred_at,
          received_at: received_at, retained: retained, qos: qos,
          properties: properties).record
    end

    def record_packet!(packet_hash)
      record(**packet_hash)
    end

    # Called by the ingest right after SUBSCRIBE, before the broker starts
    # replaying retained messages: opens the dedupe window.
    def begin_session!
      now = monotonic
      @dedupe_mutex.synchronize do
        @seen_digests.delete_if { |_key, seen_at| now - seen_at > DEDUPE_WINDOW }
        @dedupe_until = now + DEDUPE_WINDOW
      end
    end

    # True when this exact (topic, payload) already arrived inside the
    # post-SUBSCRIBE window. The first occurrence is remembered and kept.
    def retained_replay?(topic, payload)
      now = monotonic
      @dedupe_mutex.synchronize do
        return false if now > @dedupe_until

        key = "#{topic}\u0000#{Digest::SHA256.hexdigest(payload.to_s)}"
        return true if @seen_digests.key?(key)

        @seen_digests[key] = now
        false
      end
    end

    # Who executed a request, remembered in-process so a burst of
    # progress events does not re-query the DB for every packet.
    def remember_executor(key, agent_id)
      return if key.blank? || agent_id.blank?

      @executors_mutex.synchronize do
        @executors.delete(key)
        @executors[key] = agent_id
        @executors.shift while @executors.size > EXECUTOR_CACHE_MAX
      end
    end

    def cached_executor(key)
      @executors_mutex.synchronize { @executors[key] }
    end

    def heartbeat!(at:, lag_ms: nil)
      @pending_heartbeats = @pending_heartbeats.to_i + 1
      @pending_lag_ms = lag_ms if lag_ms
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_heartbeat && (now - @last_heartbeat) < HEARTBEAT_INTERVAL

      @last_heartbeat = now
      pending = @pending_heartbeats
      lag = @pending_lag_ms
      @pending_heartbeats = 0
      @pending_lag_ms = nil
      IngestStatus.bump!(at: at, by: pending, lag_ms: lag)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[observer] heartbeat failed: #{e.class}: #{e.message}")
    end

    def reset_heartbeat!
      @last_heartbeat = nil
      @pending_heartbeats = 0
      @pending_lag_ms = nil
    end

    # Clears every piece of in-process state (tests, mainly).
    def reset_cache!
      @executors_mutex.synchronize { @executors.clear }
      @dedupe_mutex.synchronize do
        @seen_digests.clear
        @dedupe_until = 0.0
      end
      reset_heartbeat!
      @since_prune = 0
    end

    def prune_if_due!
      @since_prune = @since_prune.to_i + 1
      return if @since_prune < PRUNE_EVERY

      @since_prune = 0
      prune!
    end

    # Keep the observatory bounded: drop packets older than `days` and, if
    # still over `max`, the oldest rows. A nil or non-positive `max` means
    # "no cap" — never `max <= 0` becoming "delete everything".
    # Default grace before an agent row with no packets left is dropped.
    AGENT_RETENTION_DAYS = 30

    def prune!(days: retention_days, max: max_packets, agent_days: agent_retention_days)
      deleted = 0
      if days.to_i.positive?
        deleted += Packet.where("occurred_at < ?", days.to_i.days.ago).delete_all
      end

      cap = max.nil? ? nil : max.to_i
      if cap&.positive?
        excess = Packet.count - cap
        if excess.positive?
          ids = Packet.order(id: :asc).limit(excess).pluck(:id)
          deleted += Packet.where(id: ids).delete_all
        end
      end

      pruned_agents = prune_agents!(days: agent_days)

      if deleted.positive?
        refresh_agent_counts!
        Rails.logger.info("[observer] pruned #{deleted} packet(s)")
      end
      Rails.logger.info("[observer] pruned #{pruned_agents} agent(s)") if pruned_agents.positive?
      deleted
    end

    # Agents used to accumulate forever: they were never part of retention, so
    # a long-lived observer's fleet table grew without bound even though the
    # packet table did not (doc5.md O5-6). Only agents with nothing left to
    # show are removed, and only after a long grace period.
    def prune_agents!(days: agent_retention_days)
      cutoff_days = days.to_i
      return 0 unless cutoff_days.positive?

      cutoff = cutoff_days.days.ago
      stale = Agent.where("last_seen_at < ?", cutoff)
      removed = 0
      stale.find_each do |agent|
        next if Packet.where(agent_id: agent.agent_id).exists?

        agent.destroy
        removed += 1
      end
      removed
    end

    def agent_retention_days
      ENV.fetch("RUNES_OBSERVER_AGENT_RETENTION_DAYS", AGENT_RETENTION_DAYS.to_s).to_i
    end

    # The packet_count column is a cached count of attributed packets; a
    # prune can delete rows behind its back, so rebuild it afterwards.
    def refresh_agent_counts!
      Agent.find_each do |agent|
        agent.update_columns(packet_count: Packet.for_agent(agent.agent_id).count)
      end
    end

    def retention_days
      parse_positive_env("RUNES_OBSERVER_RETENTION_DAYS", DEFAULT_RETENTION_DAYS)
    end

    def max_packets
      value = ENV["RUNES_OBSERVER_MAX_PACKETS"]
      return DEFAULT_MAX_PACKETS if value.blank?

      parsed = Integer(value, exception: false)
      if parsed.nil?
        Rails.logger.warn("[observer] RUNES_OBSERVER_MAX_PACKETS=#{value.inspect} is not a number; " \
                          "running with no packet cap")
        return nil
      end

      # <= 0 means "no cap" (the old code turned 0 into `prune!(days: 0)`,
      # which deleted the whole table).
      parsed.positive? ? parsed : nil
    end

    private

    def parse_positive_env(name, fallback)
      value = ENV[name]
      return fallback if value.blank?

      parsed = Integer(value, exception: false)
      return parsed if parsed

      Rails.logger.warn("[observer] #{name}=#{value.inspect} is not a number; using #{fallback}")
      fallback
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  def initialize(topic:, payload:, occurred_at: nil, received_at: Time.current, retained: false,
                 qos: nil, properties: nil)
    @topic = topic.to_s
    raw = payload.to_s
    # MQTT payloads are arbitrary bytes: sqlite3 raises
    # Encoding::UndefinedConversionError when it binds an invalid UTF-8
    # string, and one hostile/buggy publisher must not wedge ingest. Repair
    # at the storage boundary, and remember that the repair was lossy.
    utf8 = raw.dup.force_encoding(Encoding::UTF_8)
    @scrubbed = !utf8.valid_encoding?
    @payload = utf8.scrub
    @bytesize = raw.bytesize
    # Deliberately NOT `|| received_at` here: #record has to be able to tell
    # "the caller gave us a time" from "nobody did", because the payload may
    # carry the publisher's own clock. Defaulting here made that distinction
    # impossible and silently disabled the clock extraction.
    @occurred_at = occurred_at
    @received_at = received_at
    @retained = retained
    @qos = qos
    # `Runes::Transport::Message#properties` is the transport-neutral
    # subset (`response_topic`, `correlation_id`, `user_properties`); the
    # inproc hub also marks retained replays with `{retained: true}`, which
    # is not a real property and is not stored as one.
    @properties = properties.is_a?(Hash) ? properties : {}
  end

  def record
    result = PacketClassifier.call(topic: @topic, payload: @payload)
    data = PacketClassifier.parse(@payload)
    agent_id = result.agent_id || inferred_executor(result)
    body, truncated = truncate(@payload)
    publisher_at = @occurred_at || publisher_time(data)
    @occurred_at = publisher_at || @received_at
    signature = signature_of(data)

    packet = Packet.create!(
      topic: @topic,
      payload: body,
      payload_bytes: @bytesize,
      truncated: truncated,
      scrubbed: @scrubbed,
      agent_id: agent_id,
      request_id: result.request_id,
      run_id: result.run_id,
      kind: result.kind,
      event: result.event,
      tool: result.tool,
      occurred_at: @occurred_at,
      received_at: @received_at,
      qos: @qos,
      retain: @retained,
      correlation_id: @properties[:correlation_id].presence,
      response_topic: @properties[:response_topic].presence,
      user_properties: user_properties_json,
      signature_state: signature.state,
      key_fingerprint: signature.fingerprint.presence
    )

    self.class.remember_executor(correlation_key(result), agent_id)
    update_agent(result, agent_id, data, retained: @retained)
    attribute_packet(result, agent_id)
    # A workflow telemetry event is also a packet, but the run view reads the
    # projected rows, so fold it into WorkflowRun/WorkflowStep here.
    project_workflow_event(packet)
    self.class.heartbeat!(at: @received_at, lag_ms: lag_ms(publisher_at))
    self.class.prune_if_due!
    packet
  end

  # Telemetry must never break ingest: a bad event is logged and skipped.
  def project_workflow_event(packet)
    return unless packet.kind == "workflow_event"

    WorkflowRunProjector.apply(packet)
  end

  private

  def correlation_key(result)
    return "request:#{result.request_id}" if result.request_id.present?

    nil
  end

  # The publisher's own clock, when the payload carries one: the journal writes
  # `at` (ISO 8601) and a signed envelope carries `ts` (unix seconds). Neither
  # used to reach the row — `occurred_at` was always our receipt time, which
  # made a packet's real age unknowable and an ingest-lag measurement
  # impossible (doc5.md O0.5).
  #
  # A payload may claim any time it likes, so a clock is trusted only when it
  # is plausible: a stale or future timestamp would silently reorder the
  # timeline and poison the lag figure. Rejected clocks leave occurred_at as
  # the receipt time, which is what it always was.
  MAX_CLOCK_SKEW_S = 60
  MAX_CLOCK_AGE_S = 7 * 24 * 60 * 60

  def publisher_time(data)
    return nil unless data.is_a?(Hash)

    raw = data["at"] || data["ts"]
    time = case raw
           when String then safe_iso8601(raw)
           when Numeric then Time.at(raw)
           end
    return nil if time.nil?

    now = Time.current
    return nil if time > now + MAX_CLOCK_SKEW_S
    return nil if time < now - MAX_CLOCK_AGE_S

    time.utc
  end

  def safe_iso8601(raw)
    Time.iso8601(raw)
  rescue ArgumentError, TypeError
    nil
  end

  # How far behind the publisher's clock this packet arrived. nil when the
  # publisher sent no clock: "unknown" is honest, 0 would not be.
  def lag_ms(publisher_at)
    return nil if publisher_at.nil?

    [((@received_at - publisher_at) * 1000).round, 0].max
  end

  # Who signed this, if anyone (doc5.md O0.3). Verification must never be able
  # to break ingest — a witness that stops recording because a signature is
  # odd is worse than one that records the oddity. The service itself fails
  # closed; this is the second belt.
  def signature_of(data)
    ObserverSignature.check(data)
  rescue StandardError => e
    Rails.logger.warn("[observer] signature check skipped: #{e.class}: #{e.message}")
    ObserverSignature::Result.new(state: "unsigned", fingerprint: nil, claimed_agent: nil, reason: nil)
  end

  def inferred_executor(result)
    key = correlation_key(result)
    return nil if key.nil?

    cached = self.class.cached_executor(key)
    return cached if cached.present?

    Packet.for_request(key.delete_prefix("request:")).where.not(agent_id: nil).recent.first&.agent_id
  end

  # The executor is often only known at the END of a request (the harness's
  # journal entry carries `agent`; a delegation envelope carries `from`).
  # Attribute the whole request retroactively when it becomes known, and keep
  # the agent's cached packet_count in step with the rows we just claimed.
  def attribute_packet(result, agent_id)
    return if agent_id.blank?

    claimed = 0
    if result.request_id.present?
      claimed = Packet.for_request(result.request_id).where(agent_id: nil).update_all(agent_id: agent_id)
    end
    Agent.bump_packet_count!(agent_id, by: claimed + 1)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[observer] attribution backfill failed: #{e.class}: #{e.message}")
  end

  def update_agent(result, agent_id, data, retained:)
    return if agent_id.blank?

    case result.kind
    when "card", "a2a_card"
      Agent.record_card!(agent_id, data, at: @occurred_at, touch: !retained) if data
    when "status"
      Agent.record_status!(agent_id, @payload, at: @occurred_at, touch: !retained)
    else
      Agent.touch_seen!(agent_id, at: @occurred_at)
    end
  end

  # The MQTT 5 user properties as stored JSON text, or nil when there are
  # none. Publisher-controlled, so bounded on the way in (see
  # USER_PROPERTY_LIMIT): one packet must not be able to write a megabyte of
  # headers, and a value that was cut is still valid JSON.
  def user_properties_json
    users = @properties[:user_properties]
    return nil unless users.is_a?(Hash) && users.any?

    trimmed = users.first(USER_PROPERTY_LIMIT).to_h do |key, value|
      [key.to_s[0, 128], value.to_s.byteslice(0, USER_PROPERTY_VALUE_BYTES).to_s.scrub]
    end
    JSON.generate(trimmed)
  end

  def truncate(text)
    return [text, false] if text.bytesize <= MAX_PAYLOAD_BYTES

    # scrub can grow a torn multibyte character into a 3-byte U+FFFD, which
    # would land above the cap again; drop whole characters until it holds.
    cut = text.byteslice(0, MAX_PAYLOAD_BYTES).to_s.scrub
    cut = cut[0...-1] while cut.bytesize > MAX_PAYLOAD_BYTES
    [cut, true]
  end
end
