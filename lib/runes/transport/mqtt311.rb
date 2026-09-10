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

      RECONNECT_INITIAL = 1.0
      RECONNECT_MAX = 30.0

      attr_reader :reconnects

      def initialize(host: "127.0.0.1", port: 1883, will: nil, keepalive: 30,
                     connect_timeout: 10, reconnect: true,
                     reconnect_initial: RECONNECT_INITIAL, reconnect_max: RECONNECT_MAX,
                     on_health: nil, **options)
        super(**options)
        @host = host
        @port = port
        @will = will
        @keepalive = keepalive
        @connect_timeout = connect_timeout
        @reconnect = reconnect ? true : false
        @reconnect_initial = reconnect_initial.to_f
        @reconnect_max = reconnect_max.to_f
        @on_health = on_health
        @reconnects = 0
        @disconnecting = false
        @client = nil
        @reader = nil
        @connected = false
      end

      def connect
        @disconnecting = false
        open_client!
        @reader = Thread.new { read_loop }
        @reader.name = "runes-mqtt311-reader"
        self
      end

      # Establish the client and subscribe nothing; the caller registers
      # subscriptions and #read_loop replays them after a reconnect.
      def open_client!
        client = ::MQTT::Client.new(host: @host, port: @port, client_id: @client_id,
                                    keep_alive: @keepalive, connect_timeout: @connect_timeout)
        client.set_will(*@will) if @will
        client.connect
        @client = client
        @connected = true
        # The gem owns an internal read thread that raises on a dropped
        # socket. Reconnecting is OUR job, so that exception is expected and
        # must not look like a crash: silence it, the same way command_runner,
        # plugins/map and workflow/task silence threads they expect to fail.
        read_thread = client.instance_variable_get(:@read_thread)
        read_thread.report_on_exception = false if read_thread.respond_to?(:report_on_exception=)
        client
      rescue Error
        raise
      rescue => e
        @connected = false
        raise Error, "MQTT 3.1.1 connect to #{@host}:#{@port} failed: #{e.class}: #{e.message}"
      end

      def disconnect
        @disconnecting = true
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

      # Same shape as the MQTT 5 reader (doc5.md T5-1): a dropped connection
      # is re-established and every live subscription re-sent, instead of the
      # adapter going quietly deaf while still reporting connected.
      def read_loop
        loop do
          begin
            consume_packets
          rescue StandardError => e
            @connected = false
            warn "[Transport] MQTT 3.1.1 reader for #{@host}:#{@port}: #{e.class}: #{e.message}" unless @disconnecting
          end
          break if @disconnecting || !@reconnect

          health(:disconnected, reason: "connection lost")
          client = reconnect!
          break if client.nil?
        end
      rescue StandardError => e
        warn "[Transport] MQTT 3.1.1 reader stopped: #{e.class}: #{e.message}" unless @disconnecting
      ensure
        @connected = false
      end

      # Consume the gem's read queue WITH A TIMEOUT.
      #
      # Why not `@client.get`: the gem owns a read thread that raises on a
      # dropped socket and simply stops. `get` then blocks on an empty queue
      # forever, so the adapter never learns the connection is gone — it goes
      # silent while reporting `connected? == true`, which is exactly the
      # T5-1 failure mode in its 3.1.1 form. Polling the queue costs one wake
      # per POLL_INTERVAL and makes the drop observable.
      POLL_INTERVAL = 0.5

      def consume_packets
        queue = @client.instance_variable_get(:@read_queue)
        gem_thread = @client.instance_variable_get(:@read_thread)
        raise Error, 'MQTT 3.1.1 client has no read queue' if queue.nil?

        loop do
          if gem_thread && !gem_thread.alive?
            raise Error, 'MQTT 3.1.1 read thread died (connection lost)'
          end

          packet = queue.pop(timeout: POLL_INTERVAL)
          next if packet.nil?

          dispatch(packet.topic, packet.payload)
          @client.puback_packet(packet) if packet.qos.to_i.positive?
        end
      end

      def reconnect!
        return nil if @disconnecting || !@reconnect

        delay = @reconnect_initial
        attempt = 0
        until @disconnecting
          sleep(delay)
          return nil if @disconnecting

          attempt += 1
          begin
            begin
              @client&.disconnect
            rescue StandardError
              nil
            end
            open_client!
            resubscribe_all!
            @reconnects += 1
            health(:reconnected, attempt: attempt)
            warn "[Transport] MQTT 3.1.1 reconnected to #{@host}:#{@port} " \
                 "(attempt #{attempt}, #{subscriptions.size} subscription(s) restored)"
            return @client
          rescue Error => e
            health(:reconnect_failed, attempt: attempt, error: e.message)
            warn "[Transport] MQTT 3.1.1 reconnect attempt #{attempt} failed: #{e.message}; retrying in #{delay}s"
            delay = [delay * 2, @reconnect_max].min
          end
        end
        nil
      end

      # Re-send every registered filter with the highest QoS any subscriber
      # asked for; the broker forgot them when the session dropped.
      def resubscribe_all!
        subscriptions.group_by(&:filter).each do |filter, subs|
          qos = subs.map { |s| s.qos.to_i }.max
          @client.subscribe(filter => qos)
        rescue StandardError => e
          warn "[Transport] MQTT 3.1.1 could not restore subscription #{filter}: #{e.message}"
        end
      end

      def health(event, **details)
        @on_health&.call(event, { host: @host, port: @port, client_id: @client_id }.merge(details))
      rescue StandardError
        nil
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
