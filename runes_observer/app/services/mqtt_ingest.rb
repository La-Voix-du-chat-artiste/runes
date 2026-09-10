require "mqtt"

# The ingest process: subscribes to the Runes fabric and records every
# packet. Runs outside the web process (`bin/runes-ingest` or
# `bin/rails runes:ingest`) and publishes its own health into
# IngestStatus so the UI can show whether the bus is being watched.
class MqttIngest
  DEFAULT_TOPIC = "runes/#"
  MAX_BACKOFF = 30

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
    disconnect
    IngestStatus.mark_disconnected!("stopped")
  end

  # Called from a signal trap: drops the client so the blocking read ends.
  def stop
    @stopping = true
    disconnect
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
