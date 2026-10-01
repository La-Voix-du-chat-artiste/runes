require_relative "base"
require_relative "../random_facade"

module Runes
  module Transport
    # Process-local transport: a small in-memory hub with MQTT-style topic
    # matching, retained messages and **native group (shared) delivery**.
    #
    # This is the reference implementation of the contract, and the default
    # for tests, the offline demos and single-process embeds: it needs no
    # broker, no ports and no network, which is why the suite no longer has
    # to wait for a TCP listener.
    class InProcess < Base
      class Hub
        def initialize(name: "default")
          @name = name
          @mutex = Mutex.new
          @subscriptions = []
          @retained = {}
          @group_cursor = Hash.new(0)
        end

        attr_reader :name

        def subscribe(filter, qos: 0, group: nil, client: nil, &block)
          group, filter = TopicFilter.split_shared(filter) if TopicFilter.shared?(filter)
          subscription = Subscription.new(Runes::Random.hex(6), filter, group, qos, block, client)
          retained = @mutex.synchronize do
            @subscriptions << subscription
            @retained.select { |topic, _payload| TopicFilter.match?(filter, topic) }.to_a
          end
          retained.each do |topic, payload|
            Transport.deliver(subscription, Message.new(topic, payload, { retained: true }, 0, true))
          end
          subscription
        end

        def unsubscribe(subscription)
          @mutex.synchronize { @subscriptions.delete(subscription) }
        end

        # Returns the number of deliveries queued. Delivery happens OUTSIDE
        # the lock so a handler that publishes back cannot deadlock.
        def publish(topic, payload, retain: false, properties: {}, qos: 0)
          raise Error, "topic #{topic.inspect} must not contain wildcards" unless TopicFilter.valid_topic?(topic)

          targets = @mutex.synchronize do
            if retain
              payload.to_s.empty? ? @retained.delete(topic) : @retained[topic] = payload.to_s
            end

            matching = @subscriptions.select do |sub|
              sub.client.nil? || sub.client.alive?
            end.select { |sub| TopicFilter.match?(sub.filter, topic) }

            # One delivery per group, round-robin across its members — the
            # shared-subscription semantics that replace the claim race.
            grouped = matching.select { |v| v.group }.group_by { |v| v.group }.map do |group, members|
              chosen = members[@group_cursor[group] % members.size]
              @group_cursor[group] += 1
              chosen
            end

            matching.reject { |v| v.group } + grouped
          end

          targets.each do |sub|
            Transport.deliver(sub, Message.new(topic, payload.to_s, properties || {}, qos, retain))
          end
          targets.size
        end

        def retained_messages
          @mutex.synchronize { @retained.dup }
        end

        def subscription_count
          @mutex.synchronize { @subscriptions.size }
        end

        def clear!
          @mutex.synchronize do
            @subscriptions.clear
            @retained.clear
            @group_cursor.clear
          end
        end
      end

      @hubs = {}
      @hubs_mutex = Mutex.new

      class << self
        def hub(name = "default")
          @hubs_mutex.synchronize { @hubs[name] ||= Hub.new(name: name) }
        end

        def reset!
          @hubs_mutex.synchronize do
            @hubs.each_value { |v| v.clear! }
            @hubs.clear
          end
        end
      end

      def initialize(hub: nil, **options)
        super(**options)
        @hub = hub || self.class.hub
        @connected = false
        @alive = true
      end

      attr_reader :hub

      def connect
        @alive = true
        @connected = true
        self
      end

      def disconnect
        subscriptions.each { |sub| @hub.unsubscribe(sub) }
        @connected = false
        @alive = false
        self
      end

      def connected?
        @connected
      end

      def alive?
        @connected && @alive
      end

      def publish(topic, payload, qos: 0, retain: false, properties: {})
        raise Error, "#{describe} is not connected" unless connected?

        @hub.publish(topic, payload, retain: retain, properties: properties, qos: qos)
      end

      def subscribe(filter, qos: 0, group: nil, &block)
        raise Error, "#{describe} is not connected" unless connected?
        raise ArgumentError, "a subscription needs a block" unless block

        effective = group ? TopicFilter.shared_filter(group, filter) : filter
        register(@hub.subscribe(effective, qos: qos, client: self, &block))
      end

      def unsubscribe(subscription)
        @hub.unsubscribe(subscription)
        super
      end

      def supports_groups?
        true
      end

      def supports_properties?
        true
      end
    end
  end
end
