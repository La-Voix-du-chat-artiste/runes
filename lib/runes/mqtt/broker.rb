require 'socket'
require 'thread'
require_relative '../transport/topic_filter'

module Runes
  module MQTT
    # A small, correct-enough MQTT 3.1.1 broker for development and
    # single-host demos. Supports: CONNECT (with Will, protocol-level
    # check), SUBSCRIBE (multi-filter, QoS echo, retained delivery),
    # UNSUBSCRIBE, PUBLISH (QoS 0/1/2 inbound with PUBACK/PUBREC, retain),
    # PINGREQ/PINGRESP, DISCONNECT, wildcard filters (`+`, `#`),
    # retained-message delivery on subscribe, and Last-Will-and-Testament
    # on unexpected disconnect.
    #
    # Hardening: declared-length reads are time-boxed against the client
    # keepalive (a silent client cannot pin a handler thread), malformed
    # remaining-length encodings drop the connection, packet/connection/
    # subscription counts are capped, retained delivery never runs user
    # callbacks under the global mutex, CONNECT must precede any other
    # packet, QoS 2 retransmissions are deduplicated, invalid Will topics
    # are refused, and retained bytes carry a total budget (S4-5).
    #
    # NOT a production broker: use Mosquitto / EMQX for anything real.
    class Broker
      KEEPALIVE_GRACE = 1.5 # multiplier on client keepalive before dropping
      MAX_PACKET_BYTES   = 1024 * 1024        # refuse oversized wire packets
      MAX_RETAINED_BYTES = 1024 * 1024        # refuse oversized retained payloads
      MAX_RETAINED_COUNT = 1_000              # cap retained-message memory
      # Total retained-payload budget (S4-5): MAX_RETAINED_COUNT alone
      # allows 1_000 x 1 MiB (~1 GiB), so bound the sum as well.
      MAX_RETAINED_TOTAL_BYTES = 8 * 1024 * 1024
      # In-flight QoS 2 packet ids are remembered per client so a
      # retransmitted PUBLISH (DUP) is acked but delivered once.
      QOS2_INFLIGHT_TTL_S = 60                # forget an id after 60s
      MAX_QOS2_INFLIGHT_PER_CLIENT = 64       # bound the dedup set
      MAX_CONNECTIONS    = 256                # handler-thread cap (S-M2)
      MAX_SUBSCRIPTIONS_PER_CLIENT = 64       # filters per client (S-M2)
      BODY_CHUNK_BYTES   = 64 * 1024          # chunked body reads (M2)
      # Absolute cap on a single packet read for keepalive-0 clients
      # (spec: no timeout — but an unbounded mid-body stall would pin a
      # handler thread forever; idle clients are never dropped).
      ABSOLUTE_PACKET_READ_S = 600

      def initialize(host = '127.0.0.1', port = 1883)
        @host = host
        @port = port
        # filter => [client, ...]
        @subscriptions = Hash.new { |h, k| h[k] = [] }
        # topic => payload (retained messages)
        @retained = {}
        # running total of @retained payload bytes (S4-5 budget)
        @retained_bytes = 0
        # client => { packet_id => monotonic time seen } for QoS 2 dedup
        @qos2_inflight = Hash.new { |h, k| h[k] = {} }
        # client => { will_topic, will_payload, will_retain, will_qos, clean_disconnect }
        @wills = {}
        @clients = {}
        # client => [filters] reverse index for per-client subscription caps
        @client_filters = Hash.new { |h, k| h[k] = [] }
        # client => name (parsed client id, for logs)
        @client_names = {}
        @conn_count = 0
        @server = nil
        @stopping = false
        # `@clients` (a Hash used as a set of live sockets) already exists
        # above; #stop closes its keys so a client sees the broker vanish.
        @mutex = Mutex.new
        # client => Mutex — serializes writes to one socket so concurrent
        # fan-out threads cannot interleave packet bytes.
        @write_locks = Hash.new { |h, k| h[k] = Mutex.new }
      end

      # Locked snapshot — callers must not mutate broker state.
      def retained
        @mutex.synchronize { @retained.dup }
      end

      def run
        puts "[Broker] Attempting to bind to #{@host}:#{@port}..."
        server = TCPServer.new(@host, @port)
        @server = server
        puts "[Broker] Listening on #{@host}:#{@port}"
        loop do
          client = server.accept
          if @mutex.synchronize { @conn_count >= MAX_CONNECTIONS }
            puts "[Broker] connection limit reached (#{MAX_CONNECTIONS}); refusing client"
            begin
              client.write([0x20, 0x02, 0x00, 0x03].pack('C*')) # CONNACK: server unavailable
            rescue StandardError
              nil
            end
            client.close rescue nil
            next
          end
          Thread.new(client) { |c| handle_client(c) }
        end
      rescue IOError, Errno::EBADF
        puts "[Broker] stopped" if @stopping
      rescue => e
        puts "[Broker] FATAL ERROR: #{e.message}\n#{e.backtrace.join("\n")}"
      end

      # Drop every connected client but keep listening. To a client this is
      # indistinguishable from the broker (or the network) going away, which
      # is exactly what a reconnect test needs — and unlike closing the
      # listener it cannot race a rebind.
      def disconnect_clients!
        @mutex.synchronize do
          @clients.each_key do |socket|
            socket.close
          rescue StandardError
            nil
          end
          @clients.clear
        end
        nil
      end

      # Release the port and drop every client. Idempotent; an embedder can
      # restart on the same port afterwards (Ruby's TCPServer sets
      # SO_REUSEADDR, so TIME_WAIT peers do not block the rebind).
      def stop
        @stopping = true
        begin
          @server&.close
        rescue StandardError
          nil
        end
        disconnect_clients!
        nil
      end

      def stopped?
        @stopping
      end

      # Programmatic API used by hosts that embed the broker in-process:
      # publish a message to all matching subscribers and (optionally)
      # retain it.
      def publish(topic, payload, retain: false)
        wire_and_retain(nil, topic, payload.to_s, retain)
      end

      # Programmatic subscribe — fires the block for every matched
      # message (including retained ones at registration time, delivered
      # OUTSIDE the global lock so a callback that publishes back cannot
      # deadlock — M1). Subscribing the same filter+block twice returns
      # the existing wrapper instead of double-delivering.
      def subscribe(filter, &block)
        existing = @mutex.synchronize do
          (@subscriptions[filter] || []).find do |w|
            w.respond_to?(:block) && w.block.equal?(block)
          end
        end
        return existing if existing

        wrapper = TopicCallback.new(filter, self, block)
        @mutex.synchronize { @subscriptions[filter] |= [wrapper] }
        # Deliver existing retained messages without holding the lock.
        snapshot = @mutex.synchronize { @retained.dup }
        snapshot.each do |topic, payload|
          wrapper.deliver(topic, payload) if topic_matches?(filter, topic)
        end
        wrapper
      end

      # Programmatic unsubscribe — in-process wrappers used to accumulate
      # for the broker's lifetime.
      def unsubscribe(wrapper)
        return unless wrapper.respond_to?(:filter)

        @mutex.synchronize do
          @subscriptions.each_value { |list| list.delete(wrapper) }
        end
      end

      # In-process callback wrapper. Mirrors the wire client interface
      # (routes into the subscriber's block; the broker distinguishes it
      # from a TCP socket via `respond_to?(:deliver)`).
      class TopicCallback
        def initialize(filter, broker, block)
          @filter = filter
          @broker = broker
          @block = block
        end

        attr_reader :filter, :block

        def deliver(topic, payload)
          @block.call(topic, payload)
        end
      end

      private

      # ---------- low-level packet helpers ----------

      def encode_remaining_length(bytes, io)
        loop do
          byte = bytes % 128
          bytes /= 128
          if bytes.positive?
            io.write([byte | 0x80].pack('C'))
          else
            io.write([byte].pack('C'))
            return
          end
        end
      end

      # Read exactly n bytes against a monotonic deadline, using
      # IO.select + readpartial so a client that goes silent cannot pin
      # this thread (M2/S-M3). Returns the string, nil on EOF, or :timeout.
      def read_exact(io, n, deadline)
        buf = + ''.b
        while buf.bytesize < n
          if deadline
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return :timeout if remaining <= 0
            ready = IO.select([io], nil, nil, remaining)
            return :timeout if ready.nil?
          end
          # readpartial returns as soon as SOME bytes are available —
          # io.read(n) would block until the FULL chunk arrives.
          buf << io.readpartial([n - buf.bytesize, BODY_CHUNK_BYTES].min)
        end
        buf
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError
        nil
      end

      # Monotonic deadline for one client's next packet. With keepalive 0
      # (pings disabled) the safety net still bounds a single mid-packet
      # stall; idle silence between packets stays unbounded on purpose.
      def packet_deadline(keepalive)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        budget = keepalive.to_i.zero? ? ABSOLUTE_PACKET_READ_S : keepalive.to_i * KEEPALIVE_GRACE
        now + budget
      end

      def read_packet(io, deadline)
        header = read_exact(io, 1, deadline)
        return header unless header.is_a?(String) # nil / :timeout
        b = header.unpack1('C')

        multiplier = 1
        length = 0
        continuation = false
        4.times do
          raw = read_exact(io, 1, deadline)
          return raw unless raw.is_a?(String)
          byte = raw.unpack1('C')
          length += (byte & 0x7F) * multiplier
          multiplier *= 128
          continuation = (byte & 0x80) != 0
          break unless continuation
        end
        # Spec: a 5th length byte with the continuation bit set is a
        # protocol violation — drop the connection (M9).
        return :malformed if continuation
        # Cap declared packet size before allocating — a malicious length
        # would otherwise let one client OOM the broker.
        return :oversized if length > MAX_PACKET_BYTES

        payload = length.positive? ? read_exact(io, length, deadline) : ''.b
        return payload unless payload.is_a?(String)
        return nil if payload.bytesize < length

        [b & 0xF0, payload, b & 0x0F]
      end

      # ---------- client loop ----------

      def handle_client(client)
        @mutex.synchronize { @conn_count += 1 }
        keepalive = 30
        # MQTT 3.1.1 requires CONNECT first; any other packet before a
        # completed CONNECT is a protocol violation (S-M4).
        connected = false
        loop do
          # keepalive 0 means "no timeout" per MQTT 3.1.1 (M8).
          select_timeout = keepalive.zero? ? nil : keepalive * KEEPALIVE_GRACE
          ready = IO.select([client], nil, nil, select_timeout)
          break if ready.nil?

          packet = read_packet(client, packet_deadline(keepalive))
          break if packet.nil?
          if packet == :timeout
            puts "[Broker] client #{client_name(client)} stalled mid-packet; dropping"
            break
          end
          if packet == :oversized
            puts '[Broker] oversized packet; dropping client'
            break
          end
          if packet == :malformed
            puts '[Broker] malformed remaining-length; dropping client'
            break
          end

          type, payload, flags = packet
          if type != 0x10 && !connected
            puts "[Broker] client #{client_name(client)} sent packet 0x#{type.to_s(16)} before CONNECT; dropping"
            break
          end
          case type
          when 0x10
            granted = handle_connect(client, payload)
            if granted
              keepalive = granted
              connected = true
            end
          when 0x30 then handle_publish(client, payload, flags)
          when 0x62 then handle_pubrel(client, payload) # QoS 2 release
          when 0x80 then handle_subscribe(client, payload)
          when 0xA0 then handle_unsubscribe(client, payload)
          when 0xC0 then write_lock_for(client).synchronize { client.write([0xD0, 0x00].pack('CC')) }
          when 0xE0
            mark_clean_disconnect(client)
            break
          else
            puts "[Broker] unsupported packet type 0x#{type.to_s(16)}; dropping"
            break
          end
        end
      rescue => e
        puts "[Broker] Client Error (#{client_name(client)}): #{e.message}"
      ensure
        fire_will_unless_clean(client)
        remove_client(client)
        client.close rescue nil
      end

      # ---------- packet handlers ----------

      def handle_connect(client, payload)
        return nil if payload.bytesize < 10
        proto_len = payload[0..1].unpack1('n')
        proto = payload[2, proto_len]
        return nil unless proto == 'MQTT' || proto == 'MQIsdp'

        level = payload.getbyte(2 + proto_len) || 0
        if level != 4
          # Only MQTT 3.1.1 (level 4) is supported; reject with CONNACK
          # "unacceptable protocol version" and drop.
          puts "[Broker] rejected protocol level #{level} from client"
          write_lock_for(client).synchronize { client.write([0x20, 0x02, 0x00, 0x01].pack('C*')) }
          return nil
        end

        connect_flags = payload.getbyte(2 + proto_len + 1) || 0
        keepalive = payload[proto_len + 4, 2].unpack1('n') # 0 => no timeout (honored, M8)

        cursor = 2 + proto_len + 1 + 1 + 2 # skip proto + level + flags + keepalive
        # Read client id (variable length) — kept for log correlation.
        if cursor + 2 <= payload.bytesize
          cid_len = payload[cursor, 2].unpack1('n')
          cid = payload[cursor + 2, cid_len].to_s
          @mutex.synchronize { @client_names[client] = cid }
          cursor += 2 + cid_len
        end

        # Will flag is bit 2 of connect_flags.
        if connect_flags & 0x04 != 0 && cursor + 2 <= payload.bytesize
          will_topic_len = payload[cursor, 2].unpack1('n')
          cursor += 2
          will_topic = payload[cursor, will_topic_len]
          cursor += will_topic_len
          if cursor + 2 <= payload.bytesize
            will_payload_len = payload[cursor, 2].unpack1('n')
            cursor += 2
            will_payload = payload[cursor, will_payload_len]
            will_qos = (connect_flags >> 3) & 0x03
            will_retain = (connect_flags & 0x20) != 0
            if valid_will_topic?(will_topic)
              @mutex.synchronize do
                @wills[client] = {
                  topic: will_topic,
                  payload: will_payload,
                  retain: will_retain,
                  qos: will_qos,
                  clean: false
                }
              end
            else
              # MQTT 3.1.1 forbids wildcards (and an empty topic) in a
              # Will topic; an invalid one would later flow into
              # wire_and_retain as a PUBLISH topic. Keep the CONNECT but
              # drop the Will (S-M5).
              puts "[Broker] ignoring invalid Will topic '#{will_topic.to_s[0, 60]}'"
            end
          end
        end

        write_lock_for(client).synchronize { client.write([0x20, 0x02, 0x00, 0x00].pack('C*')) }
        @mutex.synchronize { @clients[client] = true }
        keepalive
      end

      def handle_subscribe(client, payload)
        return if payload.bytesize < 3
        msg_id = payload[0..1]
        cursor = 2
        granted = []
        while cursor < payload.bytesize
          break if cursor + 2 > payload.bytesize
          tlen = payload[cursor, 2].unpack1('n')
          cursor += 2
          break if cursor + tlen > payload.bytesize
          topic = payload[cursor, tlen]
          cursor += tlen
          break if cursor >= payload.bytesize
          qos = payload.getbyte(cursor)
          cursor += 1
          next if topic.nil? || topic.empty?

          # A malformed filter ('a/#/b', '#/b') is a protocol error: answer
          # with failure (0x80) instead of registering something that would
          # then match nothing — or, before X5-4, matched like a wildcard.
          unless Runes::Transport::TopicFilter.valid_filter?(topic)
            puts "[Broker] rejected malformed SUBSCRIBE filter '#{topic[0, 60]}'"
            granted << [0x80].pack('C')
            next
          end

          registered = false
          snapshot = nil
          @mutex.synchronize do
            # Per-client subscription cap (S-M2).
            if @client_filters[client].size >= MAX_SUBSCRIPTIONS_PER_CLIENT && !@client_filters[client].include?(topic)
              granted << [0x80].pack('C') # failure
              next
            end
            @subscriptions[topic] |= [client]
            @client_filters[client] |= [topic]
            registered = true
            # Snapshot retained under the SAME lock that registers the
            # filter so a concurrent retained publish cannot fan out
            # live AND appear in the snapshot (M7).
            snapshot = @retained.dup
          end
          next unless registered

          granted << [qos & 0x03].pack('C')
          # Deliver retained messages matching the just-registered filter
          # — outside the lock so slow sockets never stall the broker.
          snapshot.each do |rtopic, retained_payload|
            next unless topic_matches?(topic, rtopic)
            wire_publish(client, rtopic, retained_payload, retain_flag: true)
          end
        end
        body = msg_id + granted.join
        write_lock_for(client).synchronize do
          client.write([0x90].pack('C'))
          encode_remaining_length(body.bytesize, client)
          client.write(body)
        end
      end

      def handle_unsubscribe(client, payload)
        return if payload.bytesize < 3
        msg_id = payload[0..1]
        cursor = 2
        removed = []
        while cursor + 2 <= payload.bytesize
          tlen = payload[cursor, 2].unpack1('n')
          cursor += 2
          break if cursor + tlen > payload.bytesize
          topic = payload[cursor, tlen]
          cursor += tlen
          next if topic.nil? || topic.empty?

          @mutex.synchronize do
            @subscriptions[topic].delete(client)
            @subscriptions.delete(topic) if @subscriptions[topic].empty?
            @client_filters[client].delete(topic)
          end
          removed << topic
        end
        puts "[Broker] client #{client_name(client)} unsubscribed from #{removed.join(', ')}" unless removed.empty?
        write_lock_for(client).synchronize do
          client.write([0xB0].pack('C') + [2].pack('C') + msg_id)
        end
      end

      def handle_publish(client, payload, flags)
        return if payload.bytesize < 2
        tlen = payload[0..1].unpack1('n')
        return if payload.bytesize < 2 + tlen
        topic = payload[2, tlen]

        # Fixed-header flags: bit0=RETAIN, bits1-2=QoS, bit3=DUP.
        qos = (flags >> 1) & 0x03
        if qos.positive?
          # QoS 1/2 carry a 2-byte packet identifier that is NOT part of
          # the payload; ack it or the client retries/hangs (M3).
          return if payload.bytesize < 4 + tlen
          packet_id = payload[2 + tlen, 2]
          body = payload[(4 + tlen)..-1] || ''.b
          if qos == 1
            write_lock_for(client).synchronize { client.write([0x40, 0x02].pack('CC') + packet_id) }
          elsif qos == 2
            # QoS 2 is at-least-once here, not exactly-once: always ack a
            # PUBLISH (including a DUP retransmission) with PUBREC, but
            # fan the message out only the first time this packet id is
            # seen so a retransmit cannot double-deliver (S4-4).
            duplicate = qos2_duplicate?(client, packet_id)
            write_lock_for(client).synchronize { client.write([0x50, 0x02].pack('CC') + packet_id) }
            return if duplicate
          else
            return # QoS 3 is invalid
          end
        else
          body = payload[(2 + tlen)..-1] || ''.b
        end

        # Wildcards are invalid in PUBLISH topic names (M10).
        if topic.include?('+') || topic.include?('#')
          puts "[Broker] rejected PUBLISH with wildcard in topic '#{topic[0, 60]}'"
          return
        end

        retain = (flags & 0x01) != 0
        wire_and_retain(client, topic, body, retain)
      end

      def handle_pubrel(client, payload)
        return if payload.bytesize < 2
        packet_id = payload[0, 2]
        write_lock_for(client).synchronize { client.write([0x70, 0x02].pack('CC') + packet_id) }
      end

      # Record a QoS 2 packet id (bounded by MAX_QOS2_INFLIGHT_PER_CLIENT
      # and expired after QOS2_INFLIGHT_TTL_S) and report whether it was
      # already in flight — i.e. a duplicate PUBLISH that must be acked
      # but not delivered again.
      def qos2_duplicate?(client, packet_id)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex.synchronize do
          inflight = @qos2_inflight[client]
          inflight.delete_if { |_id, seen_at| now - seen_at > QOS2_INFLIGHT_TTL_S }
          if inflight.key?(packet_id)
            inflight[packet_id] = now # refresh so a slow handshake survives
            true
          else
            # A publisher that never completes the handshake must not grow
            # the set without bound — evict the oldest entry.
            if inflight.size >= MAX_QOS2_INFLIGHT_PER_CLIENT
              oldest = inflight.min_by { |_id, seen_at| seen_at }
              inflight.delete(oldest.first) if oldest
            end
            inflight[packet_id] = now
            false
          end
        end
      end

      # Retained-message bookkeeping. MUST be called with @mutex held.
      # An empty payload deletes the topic; updates to EXISTING topics
      # always win (a restarting agent's card refresh must not be
      # refused), while brand-new topics are refused once either the
      # count cap or the total-byte budget (S4-5) is reached, so a
      # hostile publisher cannot wipe stored state (S-M1) or OOM the
      # broker. @retained_bytes tracks the sum to make the check O(1).
      def store_retained(topic, payload)
        if payload.empty?
          old = @retained.delete(topic)
          @retained_bytes -= old.bytesize if old
          return
        end
        return if payload.bytesize > MAX_RETAINED_BYTES

        if @retained.key?(topic)
          @retained_bytes += payload.bytesize - @retained[topic].bytesize
          @retained[topic] = payload.dup
        elsif @retained.size >= MAX_RETAINED_COUNT
          puts "[Broker] retained cap reached; refusing new topic #{topic[0, 60]}"
        elsif @retained_bytes + payload.bytesize > MAX_RETAINED_TOTAL_BYTES
          puts "[Broker] retained byte budget reached; refusing new topic #{topic[0, 60]}"
        else
          @retained[topic] = payload.dup
          @retained_bytes += payload.bytesize
        end
      end

      def wire_and_retain(sender, topic, payload, retain)
        # Retain bookkeeping first (under the lock), then fan out with a
        # snapshot so neither socket writes nor subscriber callbacks run
        # under the global mutex — a callback that publishes back must not
        # deadlock, and a slow socket must not stall the broker.
        deliver_to = nil
        @mutex.synchronize do
          store_retained(topic, payload) if retain

          targets = []
          @subscriptions.each do |filter, subs|
            next unless topic_matches?(filter, topic)
            subs.each { |sub| targets << sub }
          end
          targets.uniq! # overlapping filters (a/#, a/b) must not double-deliver
          deliver_to = targets
        end

        dead = []
        deliver_to.each do |sub|
          begin
            if sub.respond_to?(:deliver)
              sub.deliver(topic, payload)
            else
              wire_publish(sub, topic, payload, retain_flag: retain)
            end
          rescue => e
            dead << sub
            if sub.respond_to?(:deliver)
              # A raising in-process callback used to be silently dropped
              # from EVERY filter; scope the removal to its own filter
              # and log it (M5).
              puts "[Broker] in-process subscriber for '#{sub.filter}' raised #{e.class}: #{e.message}"
            else
              puts "[Broker] dead subscriber (#{client_name(sub)}): #{e.class} — will fire via handler ensure"
            end
          end
        end

        unless dead.empty?
          @mutex.synchronize do
            dead.each do |sub|
              if sub.respond_to?(:deliver)
                @subscriptions[sub.filter]&.delete(sub)
              else
                # NOTE: the will is deliberately NOT deleted here — the
                # client's own handler thread notices the dead socket and
                # its `ensure` fires the Last Will (M4).
                @subscriptions.each_value { |list| list.delete(sub) }
                @client_filters.delete(sub)
                @write_locks.delete(sub)
              end
            end
          end
        end
      end

      def write_lock_for(client)
        @mutex.synchronize { @write_locks[client] }
      end

      def wire_publish(client, topic, payload, retain_flag: false)
        header = retain_flag ? 0x31 : 0x30
        body = [topic.bytesize].pack('n') + topic + payload
        # Serialize per-socket so concurrent fan-out threads cannot
        # interleave packet bytes mid-write. Lock creation is guarded by
        # the global mutex; the (possibly slow) write is not.
        write_lock_for(client).synchronize do
          client.write([header].pack('C'))
          encode_remaining_length(body.bytesize, client)
          client.write(body)
        end
      end

      def mark_clean_disconnect(client)
        @mutex.synchronize do
          if (will = @wills[client])
            will[:clean] = true
          end
        end
      end

      # MQTT 3.1.1 forbids wildcards in a Will topic, and an empty topic
      # would produce an unroutable PUBLISH when the Will fires (S-M5).
      def valid_will_topic?(topic)
        !topic.to_s.empty? && !topic.include?('+') && !topic.include?('#')
      end

      def fire_will_unless_clean(client)
        will = @mutex.synchronize { @wills.delete(client) }
        return if will.nil? || will[:clean]
        puts "[Broker] firing Last Will for #{client_name(client)} on #{will[:topic]}"
        wire_and_retain(client, will[:topic], will[:payload].to_s, will[:retain])
      end

      def remove_client(client)
        @mutex.synchronize do
          @clients.delete(client)
          @client_filters.delete(client)
          @client_names.delete(client)
          @subscriptions.each_value { |list| list.delete(client) }
          @wills.delete(client)
          @qos2_inflight.delete(client)
          @write_locks.delete(client)
          @conn_count -= 1 if @conn_count.positive?
        end
      end

      def client_name(client)
        name = @mutex.synchronize { @client_names[client] }
        name ? name[0, 40] : 'unknown'
      end

      # One matcher for the whole project (doc5.md X5-4): the broker used to
      # carry a copy that over-matched a mid-filter '#' and swept up
      # '$'-prefixed topics, so an in-process subscriber saw traffic a real
      # broker would never deliver.
      def topic_matches?(filter, topic)
        Runes::Transport::TopicFilter.match?(filter, topic)
      end
    end
  end
end
