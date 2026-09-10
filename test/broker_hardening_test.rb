require 'socket'
require 'timeout'
require_relative 'test_helper'

# Regression tests for the broker hardening fixes:
#   * QoS 2 retransmission must be acked but delivered only once
#   * no packet may be handled before a completed CONNECT
#   * an invalid (wildcard / empty) Will topic is never stored
#   * retained storage is bounded by a total-byte budget (S4-5)
class TestBrokerHardening < Minitest::Test
  def setup
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @thread = Thread.new { @broker.run }
    wait_for_port(@port)
  end

  def teardown
    @thread&.kill
    @thread&.join(0.5)
  end

  # --- 1. duplicate QoS 2 PUBLISH is delivered once -------------------

  def test_duplicate_qos2_publish_is_delivered_once
    received = Queue.new
    sub = ::MQTT::Client.connect('127.0.0.1', @port, client_id: 'qos2-sub')
    sub.subscribe('qos2/dup')
    reader = Thread.new { sub.get { |_t, m| received << m } }
    sleep 0.1

    pub = raw_connect(client_id: 'qos2-pub')

    # First PUBLISH (packet id 7): fanned out once.
    pub.write(publish_packet('qos2/dup', 'once', qos: 2, packet_id: 7))
    assert_equal [0x50, 0x02, 0x00, 0x07], read_bytes(pub, 4).bytes

    # Retransmission of the same packet id: PUBREC again, no redelivery.
    pub.write(publish_packet('qos2/dup', 'once', qos: 2, packet_id: 7, dup: true))
    assert_equal [0x50, 0x02, 0x00, 0x07], read_bytes(pub, 4).bytes
    assert_equal 'once', Timeout.timeout(5) { received.pop }
    sleep 0.4
    assert received.empty?, "duplicate QoS 2 PUBLISH was delivered again (#{received.size} extra)"

    # A new packet id is a new message and must still be delivered.
    pub.write(publish_packet('qos2/dup', 'twice', qos: 2, packet_id: 8))
    assert_equal [0x50, 0x02, 0x00, 0x08], read_bytes(pub, 4).bytes
    assert_equal 'twice', Timeout.timeout(5) { received.pop }
  ensure
    reader&.kill
    pub&.close rescue nil
    sub&.disconnect rescue nil
  end

  # --- 2. PUBLISH before CONNECT is rejected --------------------------

  def test_publish_before_connect_is_rejected
    sock = TCPSocket.new('127.0.0.1', @port)
    sock.write(publish_packet('early/bird', 'nope', retain: true))

    assert wait_closed(sock), 'broker should drop a client that publishes before CONNECT'
    sleep 0.1
    refute @broker.retained.key?('early/bird'),
           'a pre-CONNECT PUBLISH must not be retained'
  ensure
    sock&.close rescue nil
  end

  # --- 3. invalid Will topics are not stored --------------------------

  def test_will_topic_with_wildcard_or_empty_is_not_stored
    wildcard = raw_connect(client_id: 'bad-will', will_topic: 'runes/bad/#',
                           will_payload: 'offline', will_retain: true)
    empty = raw_connect(client_id: 'empty-will', will_topic: '',
                        will_payload: 'offline', will_retain: true)

    # Abrupt close would fire any Will the broker accepted.
    wildcard.close
    empty.close
    sleep 0.5

    assert_empty @broker.retained,
                 'an invalid Will topic must not be stored (or published)'
  ensure
    wildcard&.close rescue nil
    empty&.close rescue nil
  end

  # --- 4. retained total-byte budget (S4-5) ---------------------------

  def test_retained_total_byte_budget_refuses_new_topic
    chunk = 'x' * Runes::MQTT::Broker::MAX_RETAINED_BYTES
    slots = Runes::MQTT::Broker::MAX_RETAINED_TOTAL_BYTES / chunk.bytesize
    slots.times { |i| @broker.publish("budget/#{i}", chunk, retain: true) }
    assert_equal slots, @broker.retained.size

    # One more byte would exceed the budget: a NEW topic must be refused.
    assert_output(/retained byte budget/) do
      @broker.publish('budget/new', 'y', retain: true)
    end
    refute @broker.retained.key?('budget/new'), 'new topic over the byte budget must be refused'

    # An update to an EXISTING topic still wins at the budget edge.
    @broker.publish('budget/0', 'refreshed', retain: true)
    assert_equal 'refreshed', @broker.retained['budget/0']

    # An empty retained payload still deletes the topic.
    @broker.publish('budget/1', '', retain: true)
    refute @broker.retained.key?('budget/1'), 'empty retained payload must delete the topic'
  end

  private

  # ---- raw MQTT 3.1.1 framing helpers (no client library handshake) ----

  def encode_remaining_length(length)
    out = String.new(encoding: Encoding::BINARY)
    loop do
      byte = length % 128
      length /= 128
      if length.positive?
        out << (byte | 0x80)
      else
        out << byte
        return out
      end
    end
  end

  def packet(type_byte, body)
    [type_byte].pack('C') + encode_remaining_length(body.bytesize) + body
  end

  def connect_packet(client_id: 'hardening', keepalive: 30, will_topic: nil,
                     will_payload: '', will_qos: 0, will_retain: false)
    flags = 0x02 # clean session
    if will_topic
      flags |= 0x04
      flags |= (will_qos & 0x03) << 3
      flags |= 0x20 if will_retain
    end

    body = [4].pack('n') + 'MQTT'.b + [4, flags].pack('CC') + [keepalive].pack('n')
    body << [client_id.bytesize].pack('n') + client_id.b
    if will_topic
      body << [will_topic.bytesize].pack('n') + will_topic.b
      body << [will_payload.bytesize].pack('n') + will_payload.b
    end
    packet(0x10, body)
  end

  def publish_packet(topic, payload, qos: 0, packet_id: 1, dup: false, retain: false)
    flags = (qos & 0x03) << 1
    flags |= 0x08 if dup
    flags |= 0x01 if retain

    body = [topic.bytesize].pack('n') + topic.b
    body << [packet_id].pack('n') if qos.positive?
    body << payload.b
    packet(0x30 | flags, body)
  end

  def raw_connect(client_id:, keepalive: 30, **will)
    sock = TCPSocket.new('127.0.0.1', @port)
    sock.write(connect_packet(client_id: client_id, keepalive: keepalive, **will))
    connack = read_bytes(sock, 4)
    assert_equal [0x20, 0x02, 0x00, 0x00], connack.bytes,
                 'expected a successful CONNACK'
    sock
  end

  def read_bytes(sock, count)
    Timeout.timeout(5) do
      buf = String.new(encoding: Encoding::BINARY)
      while buf.bytesize < count
        chunk = sock.read(count - buf.bytesize)
        break if chunk.nil?
        buf << chunk
      end
      buf
    end
  end

  # True once the socket reaches EOF (i.e. the broker dropped the client).
  def wait_closed(sock, timeout: 3)
    deadline = Time.now + timeout
    while Time.now < deadline
      ready = IO.select([sock], nil, nil, 0.1)
      next if ready.nil?
      return true if sock.read_nonblock(1, exception: false).nil?
    end
    false
  rescue Errno::ECONNRESET, Errno::EPIPE, IOError
    true
  end

  def find_free_port
    s = TCPServer.new('127.0.0.1', 0)
    p = s.addr[1]
    s.close
    p
  end

  def wait_for_port(port, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        begin
          TCPSocket.new('127.0.0.1', port).close
          return
        rescue Errno::ECONNREFUSED
          sleep 0.05
        end
      end
    end
  end
end
