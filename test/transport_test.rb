require "timeout"
require "socket"
require_relative "test_helper"
require_relative "../lib/runes/transport"

# The transport contract: every adapter must behave the same for topic
# matching, retained messages, fan-out and — the point of the abstraction —
# **group (shared) delivery**, which replaced the claim/lease protocol.
class TransportContractTest < Minitest::Test
  TF = Runes::Transport::TopicFilter

  # --- topic filter ------------------------------------------------------

  def test_topic_filter_semantics
    assert TF.match?("a/+/c", "a/b/c")
    refute TF.match?("a/+/c", "a/b/d")
    refute TF.match?("a/+/c", "a/b/c/d")
    assert TF.match?("a/#", "a/b/c")
    assert TF.match?("a/#", "a")
    assert TF.match?("#", "anything/at/all")
    refute TF.match?("a/b", "a/b/c")
    assert TF.match?("runes/prompts", "runes/prompts")

    assert TF.valid_topic?("a/b")
    refute TF.valid_topic?("a/+/b")
    refute TF.valid_topic?("a/#")
    refute TF.valid_topic?("")

    assert TF.shared?("$share/g/a/b")
    assert_equal ["g", "a/b"], TF.split_shared("$share/g/a/b")
    assert_equal [nil, "a/b"], TF.split_shared("a/b")
    assert_equal "$share/g/a/b", TF.shared_filter("g", "a/b")
  end

  # --- adapters ----------------------------------------------------------

  def inproc
    @inproc ||= Runes::Transport::InProcess.new(client_id: "inproc-#{SecureRandom.hex(3)}").connect
  end

  def embedded_mqtt
    return @embedded if defined?(@embedded) && @embedded

    port = free_port
    broker = Runes::MQTT::Broker.new("127.0.0.1", port)
    Thread.new { broker.run }
    wait_for_port(port)
    transport = Runes::Transport::MQTT311.new(host: "127.0.0.1", port: port,
                                              client_id: "mqtt311-#{SecureRandom.hex(3)}",
                                              connect_timeout: 5).connect
    @embedded = [transport, broker, port]
  end

  def teardown
    @inproc&.disconnect
    if defined?(@embedded) && @embedded
      @embedded[0].disconnect
      @embedded[1] = nil
    end
  end

  def each_transport
    yield :inproc, inproc
    transport, _broker, _port = embedded_mqtt
    yield :mqtt311, transport
  end

  # --- contract ----------------------------------------------------------

  def test_publish_reaches_matching_subscribers
    each_transport do |label, transport|
      received = Queue.new
      transport.subscribe("runes/test/#{label}/+") { |m| received << m }
      transport.publish("runes/test/#{label}/one", "hello")

      message = Timeout.timeout(5) { received.pop }
      assert_equal "runes/test/#{label}/one", message.topic
      assert_equal "hello", message.payload
    end
  end

  def test_all_group_members_receive_without_a_group
    each_transport do |_label, transport|
      a = Queue.new
      b = Queue.new
      transport.subscribe("fan/out") { |m| a << m }
      transport.subscribe("fan/out") { |m| b << m }
      transport.publish("fan/out", "x")

      assert Timeout.timeout(5) { a.pop }
      assert Timeout.timeout(5) { b.pop }, "a plain subscription is fan-out, not shared"
    end
  end

  def test_group_subscription_delivers_exactly_once_round_robin
    each_transport do |_label, transport|
      next unless transport.supports_groups?

      first = Queue.new
      second = Queue.new
      transport.subscribe("work/items", group: "workers") { |m| first << m }
      transport.subscribe("work/items", group: "workers") { |m| second << m }

      6.times { |i| transport.publish("work/items", i.to_s) }
      sleep 0.2 # let delivery drain

      first_count = first.size
      second_count = second.size
      delivered = []
      delivered << first.pop until first.empty?
      delivered << second.pop until second.empty?

      assert_equal 6, delivered.size, "each message must be consumed by exactly one group member"
      assert_equal %w[0 1 2 3 4 5].sort, delivered.map(&:payload).sort
      assert_operator first_count, :>, 0, "round-robin should spread across members"
      assert_operator second_count, :>, 0
    end
  end

  def test_group_members_see_their_own_queue_not_a_broadcast
    each_transport do |_label, transport|
      next unless transport.supports_groups?

      a = Queue.new
      b = Queue.new
      transport.subscribe("work/once", group: "g1") { |m| a << m }
      transport.subscribe("work/once", group: "g2") { |m| b << m }

      2.times { |i| transport.publish("work/once", i.to_s) }
      sleep 0.2

      # Different groups each get their own copy: group is a queue, not a
      # global filter.
      assert_equal 2, a.size
      assert_equal 2, b.size
    end
  end

  def test_retained_message_is_delivered_to_late_subscribers
    each_transport do |label, transport|
      transport.publish("retained/#{label}", "last-known", retain: true)

      late = Queue.new
      transport.subscribe("retained/#{label}") { |m| late << m }
      message = Timeout.timeout(5) { late.pop }
      assert_equal "last-known", message.payload
    end
  end

  def test_properties_round_trip_where_supported
    each_transport do |_label, transport|
      next unless transport.supports_properties?

      got = Queue.new
      transport.subscribe("props/topic") { |m| got << m }
      transport.publish("props/topic", "body",
                        properties: { response_topic: "reply/here", correlation_id: "corr-1",
                                      user_properties: { "a2a-status" => "online" } })

      message = Timeout.timeout(5) { got.pop }
      assert_equal "reply/here", message.response_topic
      assert_equal "corr-1", message.correlation_id
      assert_equal "online", message.user_properties["a2a-status"]
    end
  end

  def test_mqtt311_refuses_group_subscriptions_instead_of_double_delivering
    transport, _broker, _port = embedded_mqtt
    refute transport.supports_groups?
    assert_raises(Runes::Transport::Unsupported) do
      transport.subscribe("work/items", group: "workers") { |_m| }
    end
  end

  def test_publishing_an_invalid_topic_raises
    assert_raises(Runes::Transport::Error) { inproc.publish("bad/+/topic", "x") }
  end

  def test_in_process_exposes_group_and_property_support
    assert inproc.supports_groups?
    assert inproc.supports_properties?
  end

  # --- helpers -----------------------------------------------------------

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_port(port, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        begin
          TCPSocket.new("127.0.0.1", port).close
          return
        rescue Errno::ECONNREFUSED
          sleep 0.02
        end
      end
    end
  end
end
