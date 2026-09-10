# The ingest process: subscribes to the Runes fabric through the harness's
# own transport seam and records every packet. Runs outside the web process
# (`bin/runes-ingest` or `bin/rails runes:ingest`) and publishes its own
# health into IngestStatus so the UI can show whether the bus is being
# watched.
#
# It used to own an `mqtt` 0.7 client — MQTT 3.1.1 — while the fleet moved to
# MQTT 5. The observer therefore could not see `response_topic`,
# `correlation_id` or `user_properties` for the very messages its whole job
# is to explain, and it was a second, divergent MQTT implementation in a
# project that had just finished deleting one. Both problems have the same
# fix: read the bus the way the fleet writes it (doc5.md O0.1).
#
# Reconnection is deliberately layered, not duplicated:
#   * a transient drop is the transport's business — MQTT 5 re-subscribes on
#     its own and tells us through `on_health`, which we mirror into
#     IngestStatus and into the retained-replay dedupe window;
#   * a drop that outlasts DISCONNECT_GRACE_S is ours: we raise, the run loop
#     rebuilds the whole transport with exponential backoff, and the process
#     cannot end up "connected" forever against a broker that is gone.
class FabricIngest
  # Raised when the harness transport is not on the load path at all: a
  # configuration mistake, and one worth naming precisely (see
  # config/initializers/runes_transport.rb).
  class MissingTransport < StandardError; end

  DEFAULT_TOPIC = "runes/#"
  # MQTT wildcards never match topics that start with `$`, so the A2A
  # discovery/task space needs its own subscription.
  A2A_TOPIC = "$a2a/#"
  MAX_BACKOFF = 30
  INITIAL_BACKOFF = 1
  # Retention used to run only from the packet path, so an idle broker (or a
  # wedged ingest) meant nothing was ever pruned. This thread makes pruning a
  # property of the process rather than of the traffic (doc5.md O5-6).
  PRUNE_INTERVAL_S = 900
  # How long the transport may stay down before we rebuild it ourselves.
  DISCONNECT_GRACE_S = 60
  POLL_INTERVAL_S = 0.25

  attr_reader :host, :port, :topic, :transport_kind
  # The live transport, once connected. Read-only: it exists so an operator
  # (or a test) can ask what the ingest is actually attached to when the
  # database is too busy to record the answer in IngestStatus.
  attr_reader :transport

  def initialize(host: IngestStatus.default_host,
                 port: IngestStatus.default_port,
                 topic: DEFAULT_TOPIC,
                 logger: Rails.logger,
                 transport_kind: nil,
                 transport_factory: nil,
                 poll_interval: POLL_INTERVAL_S,
                 backoff: INITIAL_BACKOFF,
                 disconnect_grace: DISCONNECT_GRACE_S)
    @host = host
    @port = port
    @topic = topic
    @logger = logger
    @stopping = false
    @transport = nil
    @poll_interval = poll_interval
    @backoff = backoff
    @disconnect_grace = disconnect_grace
    @transport_kind = transport_kind || ENV["RUNES_OBSERVER_TRANSPORT"] || ENV["RUNES_TRANSPORT"]
    # Test seam: a factory lets a test drive the loop with a scripted
    # transport (or a real inproc hub) without a broker.
    @transport_factory = transport_factory || method(:default_transport)
  end

  def run
    start_pruner
    delay = @backoff
    until @stopping
      begin
        connect_and_consume
        delay = @backoff
      rescue Interrupt
        break
      rescue StandardError, LoadError => e
        # LoadError is a ScriptError, not a StandardError: `mqtt311`'s lazy
        # `require "mqtt"` (a gem this app deliberately does not declare)
        # would otherwise kill the process instead of being retried and said
        # out loud.
        IngestStatus.mark_disconnected!("#{e.class}: #{e.message}")
        log "ingest error: #{e.class}: #{e.message}"
        log missing_dependency_hint(e)
      end
      break if @stopping

      log "reconnecting in #{delay}s"
      sleep delay
      delay = [delay * 2, MAX_BACKOFF].min
    end
  ensure
    stop_pruner
    disconnect
    IngestStatus.mark_disconnected!("stopped")
  end

  # Called from a signal trap: drops the transport so the wait loop ends.
  def stop
    @stopping = true
    stop_pruner
    disconnect
  end

  # A timer thread independent of the message path. Public so a test can start
  # it without a broker.
  def start_pruner
    return @pruner if @pruner&.alive?

    interval = ENV.fetch("RUNES_OBSERVER_PRUNE_INTERVAL_S", PRUNE_INTERVAL_S.to_s).to_f
    return nil unless interval.positive?

    @pruner = Thread.new do
      loop do
        sleep interval
        break if @stopping

        prune_once!
      end
    end
    @pruner.name = "runes-ingest-pruner" if @pruner.respond_to?(:name=)
    @pruner.report_on_exception = false if @pruner.respond_to?(:report_on_exception=)
    @pruner
  end

  def stop_pruner
    @pruner&.kill
    @pruner = nil
  end

  # One pruning pass; never raises into the caller (a locked database must not
  # take the ingest down).
  def prune_once!
    PacketRecorder.prune!
  rescue StandardError => e
    @logger.warn("[observer] prune failed: #{e.class}: #{e.message}") if @logger.respond_to?(:warn)
    0
  end

  private

  # The one dependency this app leaves to the user's judgement: the mqtt311
  # adapter needs the `mqtt` gem, which the observer does not declare because
  # mqtt5 (hand-rolled, properties) and inproc (no broker) need no gem at all.
  def missing_dependency_hint(error)
    return nil unless error.is_a?(LoadError) && error.message.to_s.include?("mqtt")

    "the mqtt311 adapter needs the mqtt gem: add `gem \"mqtt\", \"~> 0.7\"` to " \
      "runes_observer/Gemfile (or use RUNES_TRANSPORT=mqtt5 / inproc, which need nothing)"
  end

  def default_transport(kind:, host:, port:, client_id:)
    unless defined?(Runes::Transport)
      raise MissingTransport,
            "Runes::Transport is not loaded: point RUNES_HARNESS_LIB at a harness checkout"
    end

    Runes::Transport.build(kind: kind, host: host, port: port, client_id: client_id,
                           on_health: method(:on_transport_health))
  end

  def connect_and_consume
    transport = @transport_factory.call(kind: @transport_kind, host: @host, port: @port,
                                        client_id: "runes-observer-#{Process.pid}")
    @transport = transport
    transport.connect unless transport.connected?
    warn_if_process_local(transport)
    transport.subscribe(@topic) { |message| consume(message) }
    transport.subscribe(A2A_TOPIC) { |message| consume(message) }
    PacketRecorder.reset_heartbeat!
    PacketRecorder.begin_session!
    IngestStatus.mark_connected!(host: @host, port: @port, transport: transport.name)
    log "subscribed to #{@topic} and #{A2A_TOPIC} on #{@host}:#{@port} via #{transport.describe}"

    wait_until_stopped(transport)
    raise Runes::Transport::Error, "#{transport.describe} disconnected" unless @stopping
  end

  # inproc is a hub inside this process: perfectly good for an embedded
  # publisher or a test, and completely deaf to a broker-based fleet. Saying
  # so once at startup beats an observer that looks alive and sees nothing.
  def warn_if_process_local(transport)
    return unless transport.name.to_s.match?(/inprocess/i)
    return if @transport_kind.to_s.strip.downcase.start_with?("inproc")

    log "WARNING: transport fell back to inproc, which only sees messages published " \
        "inside this process; set RUNES_TRANSPORT=mqtt5 (or mqtt311) to watch a broker"
  end

  # The transport reports its own health (MQTT 5 reconnects and re-subscribes
  # under us). Mirroring it into IngestStatus is what keeps "connected" honest
  # between our connect and our disconnect.
  def on_transport_health(event, details = {})
    case event
    when :disconnected
      IngestStatus.mark_disconnected!("transport disconnected (#{details[:reason] || "unknown"})")
    when :reconnected, :connected
      IngestStatus.mark_connected!(host: @host, port: @port, transport: @transport&.name)
      # The adapter replays every retained message after re-subscribing;
      # without reopening the dedupe window a long outage would store each
      # retained card twice.
      PacketRecorder.begin_session!
    end
  rescue StandardError => e
    @logger.warn("[observer] health mirror failed: #{e.class}: #{e.message}") if @logger.respond_to?(:warn)
    nil
  end

  # Stay alive while the transport is up. Between polls the adapter's own
  # reader thread is doing the work; this loop exists so the process does not
  # exit and so a permanent outage still reaches the backoff path.
  def wait_until_stopped(transport)
    down_since = nil
    until @stopping
      if transport.connected?
        down_since = nil
      else
        down_since ||= monotonic
        if @disconnect_grace.to_f.positive? && monotonic - down_since > @disconnect_grace.to_f
          raise Runes::Transport::Error,
                "#{transport.describe} has been down for more than #{@disconnect_grace}s"
        end
      end
      sleep @poll_interval
    end
  end

  # One bad message (non-UTF-8 bytes, a locked DB, a schema surprise) must
  # not tear down the subscription: the broker would replay every retained
  # message on reconnect and the process would spin forever, duplicating
  # rows. Count it, log it, drop it, keep the connection.
  def consume(message)
    PacketRecorder.record(topic: message.topic, payload: message.payload,
                          retained: message.retain, qos: message.qos,
                          properties: message.properties)
  rescue StandardError => e
    IngestStatus.bump_dropped!
    log "dropped #{message.topic.inspect}: #{e.class}: #{e.message}"
    nil
  end

  def disconnect
    @transport&.disconnect
  rescue StandardError
    nil
  ensure
    @transport = nil
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def log(message)
    @logger.info("[observer] #{message}")
  end
end
