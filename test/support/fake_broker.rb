# frozen_string_literal: true

require "socket"
require "timeout"

# A minimal, scriptable MQTT 5 broker for tests: a real TCP server that
# speaks just enough of the wire protocol to complete CONNECT/CONNACK, accept
# SUBSCRIBEs (recording them), acknowledge PUBLISHes, answer PINGREQ — and,
# crucially, MISBEHAVE on demand:
#
#   nack_puback:   true  -> answer PUBACK with reason 0x87 (Not authorized)
#   ignore_pingreq: true -> never answer PINGREQ (half-open peer)
#   stall_reads:   true  -> complete the handshake, then stop reading
#   qos3_publish:  true  -> send a PUBLISH with the malformed QoS 3 header
#
# It exists because the socket half of the MQTT 5 adapter had zero coverage
# (doc5.md T5-1..T5-5): every lifecycle bug survived a green suite that only
# exercised the pure codec. `drop_connections!` simulates a broker restart,
# which is how the reconnect/re-subscribe fix is pinned.
class FakeBroker
  attr_reader :port

  def initialize(nack_puback: false, ignore_pingreq: false, stall_reads: false,
                 qos3_publish: false, connect_reason: 0x00)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @nack_puback = nack_puback
    @ignore_pingreq = ignore_pingreq
    @stall_reads = stall_reads
    @qos3_publish = qos3_publish
    @connect_reason = connect_reason
    @mutex = Mutex.new
    @connections = []
    @workers = []
    @connects = 0
    @subscriptions = []   # [[filter, qos], ...] across every connection
    @publishes = []       # [topic, payload]
    @stopping = false
    @acceptor = Thread.new { accept_loop }
    @acceptor.name = "fake-broker-acceptor"
  end

  def connects
    @mutex.synchronize { @connects }
  end

  def subscriptions
    @mutex.synchronize { @subscriptions.dup }
  end

  def filters
    subscriptions.map(&:first)
  end

  def publishes
    @mutex.synchronize { @publishes.dup }
  end

  def connections
    @mutex.synchronize { @connections.dup }
  end

  # Simulate the broker (or the network) going away. The next client
  # connection is accepted normally, which is what a restart looks like.
  def drop_connections!
    @mutex.synchronize do
      @connections.each { |c| c.close rescue nil }
      @connections.clear
    end
  end

  # Send an application message to the most recent client connection. Used to
  # prove that a restored subscription is really live.
  def deliver(topic, payload, qos: 0, retain: false)
    socket = @mutex.synchronize { @connections.last }
    raise "no client connected" unless socket

    socket.write(publish_packet(topic, payload, qos: qos, retain: retain))
    true
  end

  # Send the malformed QoS 3 PUBLISH (doc5.md T5-5).
  def deliver_qos3(topic, payload)
    socket = @mutex.synchronize { @connections.last }
    raise "no client connected" unless socket

    body = encode_utf8(topic) + payload.to_s.b
    socket.write([0x36, body.bytesize].pack("C2") + body) # 0x36 = PUBLISH, QoS 3
    true
  end

  def stop
    @stopping = true
    drop_connections!
    @server.close rescue nil
    @acceptor&.kill
    @mutex.synchronize { @workers.each(&:kill) }
  end

  private

  def accept_loop
    until @stopping
      begin
        client = @server.accept
      rescue StandardError
        break
      end
      @mutex.synchronize { @connections << client }
      worker = Thread.new(client) { |c| serve(c) }
      worker.name = "fake-broker-conn"
      @mutex.synchronize { @workers << worker }
    end
  rescue StandardError
    nil
  end

  def serve(client)
    read_packet(client) # CONNECT
    @mutex.synchronize { @connects += 1 }
    client.write([0x20, 0x03, 0x00, @connect_reason, 0x00].pack("C5"))
    return if @connect_reason != 0x00

    loop do
      break if @stopping
      # A peer that stops reading still holds the socket open: that is the
      # write-deadline scenario, so do not read at all.
      sleep 0.5 and next if @stall_reads

      packet = read_packet(client)
      break if packet.nil?

      type, flags, body = packet
      case type
      when 3 then handle_publish(client, flags, body)
      when 8 then handle_subscribe(client, body)
      when 12 then client.write([0xD0, 0x00].pack("C2")) unless @ignore_pingreq
      when 14 then break
      end
    end
  rescue StandardError
    nil
  ensure
    client.close rescue nil
    @mutex.synchronize { @connections.delete(client) }
  end

  def handle_publish(client, flags, body)
    qos = (flags >> 1) & 0x03
    topic, offset = read_utf8(body, 0)
    packet_id = nil
    if qos.positive?
      packet_id = ((body.getbyte(offset) || 0) << 8) | (body.getbyte(offset + 1) || 0)
      offset += 2
    end
    props_len = body.getbyte(offset) || 0
    offset += 1 + props_len
    payload = body.byteslice(offset, body.bytesize - offset).to_s
    @mutex.synchronize { @publishes << [topic, payload] }
    return unless qos == 1 && packet_id

    reason = @nack_puback ? 0x87 : 0x00
    client.write([0x40, 0x04, packet_id >> 8, packet_id & 0xFF, reason, 0x00].pack("C6"))
  end

  def handle_subscribe(client, body)
    packet_id = (body.getbyte(0) << 8) | body.getbyte(1)
    offset = 2
    props_len = body.getbyte(offset) || 0
    offset += 1 + props_len
    granted = []
    while offset < body.bytesize
      filter, offset = read_utf8(body, offset)
      qos = body.getbyte(offset) || 0
      offset += 1
      @mutex.synchronize { @subscriptions << [filter, qos] }
      granted << (qos & 0x03)
    end
    reply = [packet_id >> 8, packet_id & 0xFF, 0x00].pack("C3") + granted.pack("C*")
    client.write([0x90, reply.bytesize].pack("C2") + reply)
  end

  def publish_packet(topic, payload, qos: 0, retain: false)
    body = encode_utf8(topic)
    body << [1].pack("n") if qos.positive? # packet id 1
    body << [0x00].pack("C")               # empty properties
    body << payload.to_s.b
    [(0x30 | ((qos & 0x03) << 1) | (retain ? 1 : 0)), *remaining_length(body.bytesize)].pack("C*") + body
  end

  def encode_utf8(text)
    bytes = text.to_s.b
    [bytes.bytesize].pack("n") + bytes
  end

  def read_utf8(body, offset)
    length = ((body.getbyte(offset) || 0) << 8) | (body.getbyte(offset + 1) || 0)
    [body.byteslice(offset + 2, length).to_s, offset + 2 + length]
  end

  def remaining_length(size)
    out = []
    loop do
      byte = size % 128
      size /= 128
      byte |= 0x80 if size.positive?
      out << byte
      break if size.zero?
    end
    out
  end

  def read_packet(io)
    first = io.read(1)
    return nil if first.nil?

    multiplier = 1
    length = 0
    loop do
      byte = io.read(1)
      return nil if byte.nil?

      value = byte.getbyte(0)
      length += (value & 0x7F) * multiplier
      break if (value & 0x80).zero?

      multiplier *= 128
      return nil if multiplier > 128**3
    end
    body = length.positive? ? io.read(length) : +"".b
    return nil if body.nil? && length.positive?

    first_byte = first.getbyte(0)
    [first_byte >> 4, first_byte & 0x0F, body.to_s]
  rescue StandardError
    nil
  end
end
