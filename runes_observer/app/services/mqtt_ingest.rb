require "mqtt"

# The ingest process: subscribes to the Runes fabric and records every
# packet. Runs outside the web process (`bin/runes-ingest` or
# `bin/rails runes:ingest`) and publishes its own health into
# IngestStatus so the UI can show whether the bus is being watched.
class MqttIngest
  DEFAULT_TOPIC = "runes/#"
  MAX_BACKOFF = 30
  # Retention used to run only from the packet path, so an idle broker (or a
  # wedged ingest) meant nothing was ever pruned. This thread makes pruning a
  # property of the process rather than of the traffic (doc5.md O5-6).
  PRUNE_INTERVAL_S = 900

  attr_reader :host, :port, :topic

  def initialize(host: IngestStatus.default_host,
                 port: IngestStatus.default_port,
                 topic: DEFAULT_TOPIC,
                 logger: Rails.logger,
                 client_factory: nil)
    @host = host
    @port = port
    @topic = topic
    @logger = logger
    @stopping = false
    @client = nil
    # Test seam: a factory lets a fake broker drive the consume loop without
    # a real socket (and without needing the real broker for the suite).
    @client_factory = client_factory || method(:default_client)
  end

  def run
    start_pruner
    delay = 1
    until @stopping
      begin
        connect_and_consume
        delay = 1
      rescue Interrupt
        break
      rescue StandardError => e
        IngestStatus.mark_disconnected!("#{e.class}: #{e.message}")
        log "ingest error: #{e.class}: #{e.message}"
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

  # Called from a signal trap: drops the client so the blocking read ends.
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

  def default_client(host:, port:, client_id:)
    MQTT::Client.new(host: host, port: port, client_id: client_id)
  end

  def connect_and_consume
    client = @client_factory.call(host: @host, port: @port,
                                  client_id: "runes-observer-#{Process.pid}")
    @client = client
    client.connect
    client.subscribe(@topic => 0)
    # MQTT wildcards never match topics that start with `$`, so the A2A
    # discovery/task space needs its own subscription.
    client.subscribe("$a2a/#" => 0)
    PacketRecorder.reset_heartbeat!
    PacketRecorder.begin_session!
    IngestStatus.mark_connected!(host: @host, port: @port)
    log "subscribed to #{@topic} and $a2a/# on #{@host}:#{@port}"

    while !@stopping
      packet = client.get_packet
      break if packet.nil?

      consume(packet)
    end
  end

  # One bad message (non-UTF-8 bytes, a locked DB, a schema surprise) must
  # not tear down the subscription: the broker would replay every retained
  # message on reconnect and the process would spin forever, duplicating
  # rows. Count it, log it, drop it, keep the connection.
  def consume(packet)
    PacketRecorder.record(topic: packet.topic, payload: packet.payload,
                          retained: packet.respond_to?(:retain) && packet.retain)
  rescue StandardError => e
    IngestStatus.bump_dropped!
    log "dropped #{packet.topic.inspect}: #{e.class}: #{e.message}"
    nil
  end

  def disconnect
    @client&.disconnect
  rescue StandardError
    nil
  ensure
    @client = nil
  end

  def log(message)
    @logger.info("[observer] #{message}")
  end
end
