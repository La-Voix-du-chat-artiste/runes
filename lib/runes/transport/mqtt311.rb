require "mqtt"
require_relative "base"

module Runes
  module Transport
    # Adapter over the classic `mqtt` gem — MQTT 3.1.1.
    #
    # 3.1.1 has no shared subscriptions and no PUBLISH properties, so:
    #   * `subscribe(group:)` raises Unsupported (callers must not silently
    #     double-deliver instead), and
    #   * reply routing falls back to the `runes/.../response` topic
    #     conventions (the properties hash is accepted and ignored).
    #
    # Use this for compatibility with old brokers or when a fleet runs a
    # single consuming agent; use MQTT5 for grouped dispatch.
    class MQTT311 < Base
      attr_reader :host, :port

      def initialize(host: "127.0.0.1", port: 1883, will: nil, keepalive: 30,
                     connect_timeout: 10, **options)
        super(**options)
        @host = host
        @port = port
        @will = will
        @keepalive = keepalive
        @connect_timeout = connect_timeout
        @client = nil
        @reader = nil
        @connected = false
      end

      def connect
        client = ::MQTT::Client.new(host: @host, port: @port, client_id: @client_id,
                                    keep_alive: @keepalive, connect_timeout: @connect_timeout)
        client.set_will(*@will) if @will
        client.connect
        @client = client
        @connected = true
        @reader = Thread.new { read_loop }
        @reader.name = "runes-mqtt311-reader"
        self
      rescue Error
        raise
      rescue => e
        @connected = false
        raise Error, "MQTT 3.1.1 connect to #{@host}:#{@port} failed: #{e.class}: #{e.message}"
      end

      def disconnect
        @connected = false
        @client&.disconnect
      rescue StandardError
        nil
      ensure
        @reader&.kill
        @reader = nil
        @client = nil
      end

      def connected?
        @connected
      end

      def alive?
        @connected
      end

      def publish(topic, payload, qos: 0, retain: false, properties: {})
        raise Error, "#{describe} is not connected" unless @connected
        # Same contract as InProcess/MQTT5: a concrete topic never contains a
        # wildcard (this adapter used to accept "bad/+/topic", T5-13).
        raise Error, "topic #{topic.inspect} must not contain wildcards" unless TopicFilter.valid_topic?(topic)

        @client.publish(topic, payload.to_s, retain, qos)
      end

      def subscribe(filter, qos: 0, group: nil, &block)
        raise ArgumentError, "a subscription needs a block" unless block
        # Capability first: whether groups are possible does not depend on
        # being connected, and callers branch on this answer.
        if group
          raise Unsupported,
                "MQTT 3.1.1 has no shared subscriptions (group=#{group.inspect}); " \
                "use RUNES_TRANSPORT=mqtt5 or inproc for grouped dispatch"
        end
        raise Error, "#{describe} is not connected" unless @connected

        subscription = Subscription.new(id: SecureRandom.hex(6), filter: filter, group: nil,
                                        qos: qos, block: block, client: self)
        register(subscription)
        @client.subscribe(filter => qos)
        subscription
      end

      def unsubscribe(subscription)
        return false unless subscription

        remaining = subscriptions.reject { |sub| sub.equal?(subscription) }
        @client.unsubscribe(subscription.filter) if remaining.none? { |s| s.filter == subscription.filter }
        super
      end

      def supports_groups?
        false
      end

      def supports_properties?
        false
      end

      private

      def read_loop
        @client.get do |topic, payload|
          dispatch(topic, payload)
        end
      rescue StandardError => e
        @connected = false
        warn "[Transport] MQTT 3.1.1 reader stopped: #{e.class}: #{e.message}"
      end

      def dispatch(topic, payload)
        subscriptions.each do |subscription|
          next unless TopicFilter.match?(subscription.filter, topic)

          deliver(subscription, topic, payload)
        end
      end
    end
  end
end
