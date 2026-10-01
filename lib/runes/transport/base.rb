require_relative 'topic_filter'
require_relative '../json_facade'
require_relative '../random_facade'

module Runes
  module Transport
    class Error < StandardError; end

    # Raised when an adapter is asked for a semantic it cannot provide —
    # notably group (shared) subscriptions on plain MQTT 3.1.1.
    class Unsupported < Error; end

    # One received (or sent) application message.
    #
    # `properties` is the transport-neutral subset of MQTT 5 PUBLISH
    # properties that Runes uses, so callers never branch on the adapter:
    #
    #   response_topic:  String  — where to send the reply
    #   correlation_id:  String  — opaque request correlation token
    #   user_properties: Hash    — a2a-status, trace ids, ...
    #
    # Plain class with positional construction (no keyword_init Struct) to
    # stay inside the Spinel kernel subset.
    class Message
      attr_accessor :topic, :payload, :properties, :qos, :retain

      def initialize(topic, payload = nil, properties = nil, qos = 0, retain = false)
        # Kwargs-compat shim: callers that predate the positional constructor
        # (tests, embedders) pass topic:/payload:/...; Ruby 3 forwards those
        # as a positional Hash when the method declares no keywords. Kernel
        # code always uses the positional form.
        if topic.is_a?(Hash)
          h = topic
          topic = h[:topic]
          payload = h[:payload]
          properties = h[:properties]
          qos = h[:qos] || 0
          retain = h[:retain] || false
        end
        @topic = topic
        @payload = payload
        @properties = properties || {}
        @qos = qos
        @retain = retain
      end

      def response_topic
        properties && properties[:response_topic]
      end

      def correlation_id
        properties && properties[:correlation_id]
      end

      def user_properties
        (properties && properties[:user_properties]) || {}
      end

      def parsed
        return @parsed if defined?(@parsed)

        @parsed = begin
          payload.to_s.empty? ? nil : Runes::Json.parse(payload.to_s)
        rescue Runes::Json::ParseError
          nil
        end
      end

      # The id a request's replies are correlated by: the MQTT 5
      # Correlation Data when present, else the conventional request_id
      # field inside the envelope.
      def request_id
        correlation_id || (parsed && parsed['request_id'])
      end
    end

    # A live subscription handle returned by #subscribe. Same construction
    # rule as Message (positional, kernel subset).
    class Subscription
      attr_accessor :id, :filter, :group, :qos, :block, :client

      def initialize(id, filter, group, qos, block, client)
        @id = id
        @filter = filter
        @group = group
        @qos = qos
        @block = block
        @client = client
      end
    end

    # Invoke a subscriber, isolating faults so one bad handler cannot kill a
    # transport reader thread.
    def self.deliver(subscription, message)
      subscription.block.call(message)
    rescue => e
      warn "[Transport] subscriber for #{subscription.filter} raised #{e.class}: #{e.message}"
    end

    # Every transport adapter implements this contract. The harness only
    # ever talks to this interface, so MQTT is a choice rather than a
    # requirement.
    #
    # Semantics:
    #   * #publish is safe to call from any thread.
    #   * #subscribe delivers messages on the transport's own receive
    #     thread(s); handlers must not block for long (the dispatcher
    #     enqueues to its worker pool).
    #   * A subscription with a `group` is a *shared* subscription: each
    #     message is delivered to exactly one member of the group. This is
    #     what replaces the old claim/lease protocol. Adapters that cannot
    #     provide it must raise Unsupported rather than silently
    #     double-delivering.
    class Base
      attr_reader :client_id

      def initialize(client_id: nil, **_options)
        @client_id = client_id || "runes-#{Runes::Random.hex(4)}"
        @subscriptions = []
        @mutex = Mutex.new
      end

      def connect
        raise NotImplementedError, "#{self.class} must implement #connect"
      end

      def disconnect
        raise NotImplementedError, "#{self.class} must implement #disconnect"
      end

      def connected?
        raise NotImplementedError, "#{self.class} must implement #connected?"
      end

      def publish(_topic, _payload, qos: 0, retain: false, properties: {})
        raise NotImplementedError, "#{self.class} must implement #publish"
      end

      def subscribe(_filter, qos: 0, group: nil, &_block)
        raise NotImplementedError, "#{self.class} must implement #subscribe"
      end

      def unsubscribe(subscription)
        return false unless subscription

        @mutex.synchronize { @subscriptions.delete(subscription) }
        true
      end

      def subscriptions
        @mutex.synchronize { @subscriptions.dup }
      end

      # True when #subscribe(group:) is honoured. Callers use this to choose
      # between shared dispatch and single-agent (solo) operation instead of
      # discovering it by racing.
      def supports_groups?
        false
      end

      def supports_properties?
        false
      end

      def name
        self.class.name.split("::").last
      end

      def describe
        "#{name}(#{client_id})"
      end

      # --- helpers shared by adapters ------------------------------------

      def register(subscription)
        @mutex.synchronize { @subscriptions << subscription }
        subscription
      end

      # Build the property hash for a reply, so callers do not care whether
      # the adapter can carry MQTT 5 properties.
      def reply_properties(response_topic, correlation_id, user_properties = {})
        props = {}
        props[:response_topic] = response_topic if response_topic
        props[:correlation_id] = correlation_id.to_s if correlation_id
        props[:user_properties] = user_properties if user_properties && !user_properties.empty?
        props
      end

      # Resolve a captured block against a raw (topic, payload, properties)
      # triple. Adapters call this so Message construction stays uniform.
      def deliver(subscription, topic, payload, properties = {}, qos: 0, retain: false)
        message = Message.new(topic, payload, properties || {}, qos, retain)
        Transport.deliver(subscription, message)
      end

      def valid_qos?(qos)
        [0, 1, 2].include?(qos)
      end
    end
  end
end
