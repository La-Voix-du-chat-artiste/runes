require 'stringio'
require_relative 'test_helper'

class TestMQTTBroker < Minitest::Test
  def test_broker_initializes
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    assert_instance_of Runes::MQTT::Broker, broker
  end

  def test_handle_connect_writes_connack
    broker = Runes::MQTT::Broker.new
    written = String.new
    client = Object.new
    client.define_singleton_method(:write) { |data| written << data }

    payload = [4].pack('n') + 'MQTT' + [4, 0, 30].pack('CCn')
    remaining = broker.send(:handle_connect, client, payload)

    assert_equal [0x20, 0x02, 0x00, 0x00].pack('C*'), written
    assert_equal 30, remaining
  end

  def test_topic_matching_supports_wildcards
    broker = Runes::MQTT::Broker.new
    match = ->(filter, topic) { broker.send(:topic_matches?, filter, topic) }

    assert match.call('#', 'a/b/c')
    assert match.call('a/#', 'a/b/c')
    assert match.call('a/+', 'a/b')
    refute match.call('a/+', 'a/b/c')
    assert match.call('runes/tools/+/request', 'runes/tools/echo/request')
    refute match.call('runes/tools/+/request', 'runes/tools/echo/request/extra')
    assert match.call('a/b', 'a/b')
    refute match.call('a/b', 'a/b/c')
  end

  def test_remaining_length_encoding
    broker = Runes::MQTT::Broker.new
    encode = ->(n) {
      io = StringIO.new
      broker.send(:encode_remaining_length, n, io)
      io.string.bytes
    }
    assert_equal [0],              encode.call(0)
    assert_equal [127],            encode.call(127)
    assert_equal [128, 1],         encode.call(128)
    assert_equal [255, 127],       encode.call(16_383)
    assert_equal [128, 128, 1],    encode.call(16_384)
  end
end
