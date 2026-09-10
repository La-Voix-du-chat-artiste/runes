require 'socket'
require 'timeout'
require_relative 'test_helper'

class TestBrokerAdvanced < Minitest::Test
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

  def test_retained_message_is_delivered_to_late_subscriber
    pub = ::MQTT::Client.connect('127.0.0.1', @port)
    pub.publish('runes/retained/thing', 'sticky', retain: true)

    sleep 0.1
    sub = ::MQTT::Client.connect('127.0.0.1', @port)
    received = Queue.new
    sub.subscribe('runes/retained/thing')
    t = Thread.new { sub.get { |_t, m| received << m; break } }
    assert_equal 'sticky', Timeout.timeout(5) { received.pop }
  ensure
    t&.kill
    pub&.disconnect rescue nil
    sub&.disconnect rescue nil
  end

  def test_cleared_retained_message_is_not_delivered
    pub = ::MQTT::Client.connect('127.0.0.1', @port)
    pub.publish('runes/gone/thing', 'was here', retain: true)
    sleep 0.1
    pub.publish('runes/gone/thing', '', retain: true) # clear
    sleep 0.1

    sub = ::MQTT::Client.connect('127.0.0.1', @port)
    received = Queue.new
    sub.subscribe('runes/gone/thing')
    t = Thread.new { sub.get { |_t, m| received << m } }
    sleep 0.3
    assert received.empty?
  ensure
    t&.kill
    pub&.disconnect rescue nil
    sub&.disconnect rescue nil
  end

  def test_last_will_fires_on_unexpected_disconnect
    received = Queue.new

    watcher = ::MQTT::Client.connect('127.0.0.1', @port)
    watcher.subscribe('runes/agents/+/status')
    wt = Thread.new { watcher.get { |_t, m| received << m } }
    sleep 0.1

    doomed = ::MQTT::Client.new('127.0.0.1', @port)
    doomed.set_will('runes/agents/worker-1/status', 'offline', false, 0)
    doomed.connect
    sleep 0.1
    # Abruptly close the socket without DISCONNECT.
    doomed.instance_variable_get(:@socket)&.close rescue nil

    msg = Timeout.timeout(5) { received.pop }
    assert_equal 'offline', msg
  ensure
    wt&.kill
    watcher&.disconnect rescue nil
  end

  def test_clean_disconnect_does_not_fire_will
    received = Queue.new

    watcher = ::MQTT::Client.connect('127.0.0.1', @port)
    watcher.subscribe('runes/agents/+/status')
    wt = Thread.new { watcher.get { |_t, m| received << m } }
    sleep 0.1

    well_behaved = ::MQTT::Client.new('127.0.0.1', @port)
    well_behaved.set_will('runes/agents/worker-2/status', 'offline', false, 0)
    well_behaved.connect
    sleep 0.1
    well_behaved.disconnect # clean DISCONNECT packet

    sleep 0.4
    assert received.empty?, "expected no will on clean disconnect, got: #{received.size}"
  ensure
    wt&.kill
    watcher&.disconnect rescue nil
  end

  def test_inprocess_publish_and_subscribe
    received = Queue.new
    @broker.subscribe('runes/inproc/#') { |t, m| received << [t, m] }
    @broker.publish('runes/inproc/x', 'ping', retain: true)
    topic, payload = Timeout.timeout(2) { received.pop }
    assert_equal 'runes/inproc/x', topic
    assert_equal 'ping', payload

    # Retained value should fire immediately for a new in-process subscriber.
    got = Queue.new
    @broker.subscribe('runes/inproc/x') { |t, m| got << [t, m] }
    topic2, payload2 = Timeout.timeout(2) { got.pop }
    assert_equal 'runes/inproc/x', topic2
    assert_equal 'ping', payload2
  end

  # M1: a subscriber that publishes back from its callback (as the
  # dispatcher does when it routes into in-process delivery) must not
  # deadlock on retained delivery.
  def test_programmatic_subscribe_delivers_retained_outside_the_lock
    seen = Queue.new
    @broker.publish('deadlock/x', 'r', retain: true)
    Timeout.timeout(2) do
      @broker.subscribe('deadlock/#') do |t, m|
        seen << [t, m]
        # Re-entrant publish inside the retained-delivery callback.
        @broker.publish('deadlock/echo', m) unless t.end_with?('echo')
      end
    end
    assert_equal ['deadlock/x', 'r'], seen.pop
  end

  # M5: a raising in-process callback is logged and removed only from
  # its own filter, not from every filter it holds.
  def test_raising_callback_is_scoped_and_logged
    received = Queue.new
    boom = ->(_t, _m) { raise 'kaput' }
    @broker.subscribe('boom/one', &boom)
    @broker.subscribe('boom/two') { |t, m| received << [t, m] }
    assert_output(/in-process subscriber/, nil) do
      @broker.publish('boom/one', 'x')
    end
    @broker.publish('boom/two', 'y')
    assert_equal ['boom/two', 'y'], Timeout.timeout(2) { received.pop }
  end

  # M3: QoS 1 PUBLISH payloads must not be corrupted and must be acked.
  def test_qos1_publish_is_acked_and_payload_survives
    sub = ::MQTT::Client.connect('127.0.0.1', @port)
    received = Queue.new
    sub.subscribe('qos/one')
    st = Thread.new { sub.get { |_t, m| received << m } }
    sleep 0.1

    pub = ::MQTT::Client.connect('127.0.0.1', @port)
    pub.publish('qos/one', 'exact payload', qos: 1)
    assert_equal 'exact payload', Timeout.timeout(5) { received.pop }
  ensure
    st&.kill
    pub&.disconnect rescue nil
    sub&.disconnect rescue nil
  end

  # M2/S-M3: a client that declares a body and goes silent cannot pin a
  # handler thread — the broker timeboxes body reads and drops it.
  def test_silent_body_reader_is_dropped
    keepalive = 30
    sock = TCPSocket.new('127.0.0.1', @port)
    connect = [0x10].pack('C') + [10].pack('C') + [0x00, 0x04].pack('n') + 'MQTT' + [0x04, 0x02].pack('CC') + [1].pack('n')
    sock.write(connect)
    sleep 0.2
    # PUBLISH header declaring a big body, then silence.
    sock.write([0x30].pack('C') + [0x80, 0x01].pack('C2')) # 128 bytes declared
    # Wait past the keepalive grace (1s keepalive * 1.5)
    closed = false
    start = Time.now
    loop do
      break if Time.now - start > 3
      begin
        break if sock.eof?
      rescue Errno::ECONNRESET, Errno::EPIPE
        closed = true
        break
      end
      sleep 0.1
    end
    closed ||= begin
      sock.eof?
    rescue Errno::ECONNRESET, Errno::EPIPE
      true
    end
    assert closed, 'broker should drop a client that stalls mid-body'
  ensure
    sock&.close
  end

  # M10: wildcard topics in PUBLISH are rejected.
  def test_publish_with_wildcard_topic_is_rejected
    pub = ::MQTT::Client.connect('127.0.0.1', @port)
    pub.publish('runes/bad/+/topic', 'x')
    pub.publish('runes/bad/#', 'y')
    sleep 0.2
    assert_empty @broker.retained.select { |t, _| t.include?('+') || t.include?('#') }
  ensure
    pub&.disconnect rescue nil
  end

  private

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
