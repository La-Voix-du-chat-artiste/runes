# frozen_string_literal: true

require "timeout"

require_relative "test_helper"
require_relative "support/fake_broker"
require_relative "../lib/runes/transport"
require_relative "../lib/runes/transport/mqtt5"

# The socket half of the MQTT 5 adapter. Before doc5.md these paths had ZERO
# coverage — `mqtt5_codec_test.rb` never calls #connect — which is how a
# missing reconnect loop, an unverified PINGRESP, an unbounded write, a
# discarded PUBACK reason code and a delivered QoS 3 packet all survived a
# green suite. Each test here reproduces one of those findings.
class TransportLifecycleTest < Minitest::Test
  def setup
    @brokers = []
    @adapters = []
  end

  def teardown
    @adapters.each { |a| a.disconnect rescue nil }
    @brokers.each(&:stop)
  end

  def broker(**options)
    FakeBroker.new(**options).tap { |b| @brokers << b }
  end

  def adapter(broker, **options)
    Runes::Transport::MQTT5.new(host: "127.0.0.1", port: broker.port,
                                client_id: "lifecycle-#{rand(10_000)}",
                                reconnect_initial: 0.05, reconnect_max: 0.2,
                                **options).tap { |a| @adapters << a }
  end

  # A free port for an embedded broker (close then reuse: the same small race
  # the rest of the suite accepts).
  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_port(port, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      begin
        probe = TCPSocket.new("127.0.0.1", port)
        probe.close
        return true
      rescue StandardError
        raise "port #{port} never opened" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end
  end

  # Wait for a condition without a fixed sleep, so fast machines stay fast
  # and slow ones still pass.
  def wait_until(timeout: 5.0, interval: 0.02, message: "condition")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "timed out waiting for #{message}"
      end

      sleep interval
    end
  end

  # --- T5-1: a dropped connection is re-established and re-subscribed -----

  def test_a_lost_connection_is_reconnected_and_resubscribed
    b = broker
    a = adapter(b)
    a.connect
    received = Queue.new
    a.subscribe("runes/test/topic", qos: 1) { |m| received << m.payload }

    wait_until(message: "first SUBSCRIBE") { b.filters.include?("runes/test/topic") }
    assert_equal 1, b.connects

    # The broker goes away (restart, network cut, keepalive failure).
    b.drop_connections!

    wait_until(timeout: 8, message: "reconnect") { a.reconnects.positive? && a.connected? }
    wait_until(timeout: 5, message: "re-subscribe on the new connection") do
      b.filters.count("runes/test/topic") >= 2
    end

    # And the restored subscription actually receives traffic.
    wait_until(timeout: 5, message: "a live connection to deliver on") { !b.connections.empty? }
    b.deliver("runes/test/topic", "after-reconnect")

    assert_equal "after-reconnect", Timeout.timeout(5) { received.pop },
                 "a message published after the reconnect must reach the subscriber"
  end

  def test_reconnect_can_be_disabled
    b = broker
    a = adapter(b, reconnect: false)
    a.connect
    a.subscribe("runes/x", qos: 0) { |_m| }
    wait_until(message: "subscribe") { b.filters.include?("runes/x") }

    b.drop_connections!

    wait_until(timeout: 5, message: "the adapter to notice it is disconnected") { !a.connected? }
    sleep 0.3
    assert_equal 0, a.reconnects, "reconnect: false must not silently reconnect"
  end

  def test_health_hook_reports_disconnects_and_reconnects
    b = broker
    events = Queue.new
    a = adapter(b, on_health: ->(event, details) { events << [event, details] })
    a.connect
    a.subscribe("runes/y", qos: 0) { |_m| }
    wait_until(message: "subscribe") { b.filters.include?("runes/y") }

    b.drop_connections!

    seen = []
    Timeout.timeout(8) do
      loop do
        seen << events.pop
        break if seen.map(&:first).include?(:reconnected)
      end
    end
    assert_includes seen.map(&:first), :disconnected
    assert_includes seen.map(&:first), :reconnected
    assert_equal b.port, seen.last[1][:port]
  end

  # --- T5-2: an unanswered PINGREQ means the peer is gone -----------------

  def test_a_peer_that_never_answers_pingreq_is_dropped
    b = broker(ignore_pingreq: true)
    a = adapter(b, reconnect: false, keepalive: 1)
    a.connect
    a.subscribe("runes/z", qos: 0) { |_m| }
    wait_until(message: "subscribe") { b.filters.include?("runes/z") }

    assert a.connected?
    # keepalive 1s, grace 1.5x => the adapter must give up well inside 6s.
    wait_until(timeout: 6, message: "the half-open connection to be dropped") { !a.connected? }
  end

  # --- T5-3: a peer that stops reading cannot wedge the client ------------

  def test_a_write_to_a_non_reading_peer_times_out_instead_of_hanging
    b = broker(stall_reads: true)
    a = adapter(b, write_timeout: 0.5, reconnect: false)
    a.connect

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Runes::Transport::Error) do
      # Repeatedly publish until the socket buffer fills; with a write
      # deadline this raises instead of blocking forever.
      200.times { a.publish("big/topic", "P" * 262_144, qos: 0) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_match(/timed out|failed|closed/, error.message)
    assert_operator elapsed, :<, 30, "the write deadline must bound the block"
  end

  # --- T5-4: a rejected QoS 1 publish is visible --------------------------

  def test_a_puback_failure_is_not_reported_as_success
    b = broker(nack_puback: true)
    a = adapter(b, reconnect: false)
    a.connect

    error = assert_raises(Runes::Transport::Error) do
      a.publish!("runes/denied", "hello", qos: 1, timeout: 5)
    end
    assert_match(/rejected|Not authorized/i, error.message)

    # The fire-and-forget path records it instead of silently succeeding.
    a.publish("runes/denied", "hello", qos: 1)
    wait_until(message: "the NACK to be recorded") { !a.last_publish_error.nil? }
    assert_equal 0x87, a.last_publish_error[:reason_code]
  end

  def test_a_successful_puback_returns_true
    b = broker
    a = adapter(b, reconnect: false)
    a.connect

    assert a.publish!("runes/ok", "hello", qos: 1, timeout: 5)
    assert_nil a.last_publish_error
    wait_until(message: "the publish to arrive") { b.publishes.any? { |t, _| t == "runes/ok" } }
  end

  # --- T5-5: a malformed QoS 3 PUBLISH must not be delivered --------------

  def test_a_qos3_publish_is_treated_as_malformed
    b = broker
    a = adapter(b, reconnect: false)
    delivered = []
    a.connect
    a.subscribe("t", qos: 0) { |m| delivered << m.payload }
    wait_until(message: "subscribe") { b.filters.include?("t") }

    b.deliver_qos3("t", "qos3-payload")

    wait_until(timeout: 6, message: "the malformed connection to be dropped") { !a.connected? }
    assert_empty delivered, "a QoS 3 PUBLISH is malformed and must never be delivered"
  end

  # --- T5-1, the 3.1.1 half: same disease, same cure ----------------------

  # The 3.1.1 adapter's drop detection is "the gem's own read thread died".
  # We simulate that by killing the thread rather than closing the socket
  # under it: `mqtt` 0.7 raises MQTT::ProtocolException from that thread when
  # its socket closes, and `MQTT::Client#disconnect` then kills it mid-raise,
  # which surfaces as an exception attributed to whatever test is running.
  # Killing it is silent and is precisely the condition the adapter polls for.
  def test_mqtt311_reconnects_and_resubscribes_when_its_reader_dies
    port = find_free_port
    broker = Runes::MQTT::Broker.new("127.0.0.1", port)
    thread = Thread.new { broker.run }
    @brokers << broker
    wait_for_port(port)

    adapter = Runes::Transport::MQTT311.new(host: "127.0.0.1", port: port,
                                            client_id: "t311-#{rand(10_000)}",
                                            reconnect_initial: 0.05, reconnect_max: 0.2)
    @adapters << adapter
    adapter.connect
    received = Queue.new
    adapter.subscribe("runes/t311/topic", qos: 1) { |m| received << m.payload }
    sleep 0.3

    # Before the fix the adapter kept reporting connected while nothing was
    # reading: `MQTT::Client#get` blocks forever on a queue nobody feeds.
    gem_client = adapter.instance_variable_get(:@client)
    gem_client.instance_variable_get(:@read_thread).kill

    wait_until(timeout: 10, message: "mqtt311 reconnect") do
      adapter.reconnects.positive? && adapter.connected?
    end

    publisher = MQTT::Client.new(host: "127.0.0.1", port: port, client_id: "t311-pub-#{rand(10_000)}")
    publisher.connect
    publisher.publish("runes/t311/topic", "after-reconnect")
    publisher.disconnect

    assert_equal "after-reconnect", Timeout.timeout(8) { received.pop },
                 "the 3.1.1 adapter must re-subscribe and keep receiving after its reader dies"
  ensure
    thread&.kill
    broker&.stop
  end

  # --- connection refused is still loud at startup ------------------------

  def test_a_refused_connack_still_raises_on_connect
    b = broker(connect_reason: 0x87)
    a = adapter(b, reconnect: false)

    error = assert_raises(Runes::Transport::Error) { a.connect }
    assert_match(/refused|Not authorized/i, error.message)
  end
end
