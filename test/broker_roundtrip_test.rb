require 'socket'
require 'timeout'
require_relative 'test_helper'

class TestBrokerRoundtrip < Minitest::Test
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

  def test_pub_sub_roundtrip
    received = Queue.new
    sub = ::MQTT::Client.connect('127.0.0.1', @port, client_id: 'roundtrip-sub')
    sub.subscribe('roundtrip/#')
    t = Thread.new { sub.get { |topic, msg| received << [topic, msg] } }
    sleep 0.1

    pub = ::MQTT::Client.connect('127.0.0.1', @port, client_id: 'roundtrip-pub')
    pub.publish('roundtrip/hello', 'world')
    topic, msg = Timeout.timeout(5) { received.pop }
    assert_equal 'roundtrip/hello', topic
    assert_equal 'world', msg
  ensure
    t&.kill
    pub&.disconnect rescue nil
    sub&.disconnect rescue nil
  end

  def test_roundtrip_preserves_binary_and_multibyte_payloads
    received = Queue.new
    sub = ::MQTT::Client.connect('127.0.0.1', @port, client_id: 'bin-sub')
    sub.subscribe('bin/#')
    t = Thread.new { sub.get { |topic, msg| received << [topic, msg] } }
    sleep 0.1

    pub = ::MQTT::Client.connect('127.0.0.1', @port, client_id: 'bin-pub')
    payload = JSON.generate('text' => 'héllo wörld ●', 'n' => 42)
    pub.publish('bin/json', payload)
    topic, msg = Timeout.timeout(5) { received.pop }
    assert_equal 'bin/json', topic
    assert_equal payload.b, msg.b, 'multibyte payloads must survive the wire'
  ensure
    t&.kill
    pub&.disconnect rescue nil
    sub&.disconnect rescue nil
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
