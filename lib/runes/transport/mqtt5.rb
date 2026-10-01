require "socket"
require "securerandom"
require_relative "base"
require_relative "topic_filter"

module Runes
  module Transport
    # Adapter over MQTT 5.0, hand-rolled on a raw TCP socket.
    #
    # MQTT 5 is the only transport here that can carry both of the things
    # Runes needs for multi-agent dispatch:
    #
    #   * $share/<group>/<filter> shared subscriptions — the broker picks
    #     exactly one member per message, which is what replaced the
    #     home-grown claim/lease protocol, and
    #   * PUBLISH properties (Response Topic 0x08, Correlation Data 0x09,
    #     User Property 0x26) — request/reply routing without inventing a
    #     payload envelope.
    #
    # The already-present `mqtt` gem is 3.1.1-only, hence the local codec.
    # QoS 2 is deliberately absent: the dispatcher's contract only needs
    # at-most/at-least-once, and PUBREC/PUBREL state is not worth the risk.
    class MQTT5 < Base
      # --- MQTT 5 wire codec ------------------------------------------------
      #
      # Pure functions over binary strings so the packet layout can be unit
      # tested byte-for-byte without a socket. Everything here is
      # module_function.
      module Codec
        # Property value types, per MQTT 5.0 §2.2.2.2. The *whole* table is
        # needed even though Runes only reads three ids: an unknown id must
        # still be skipped with the right width or the rest of the packet
        # misparses. A genuinely unknown id is a protocol error.
        BYTE = 0
        TWO_BYTE = 1
        FOUR_BYTE = 2
        VARINT = 3
        BINARY = 4
        UTF8 = 5
        UTF8_PAIR = 6

        PROPERTY_TYPES = {
          0x01 => BYTE,        # Payload Format Indicator
          0x02 => FOUR_BYTE,   # Message Expiry Interval
          0x03 => UTF8,        # Content Type
          0x08 => UTF8,        # Response Topic
          0x09 => BINARY,      # Correlation Data
          0x0B => VARINT,      # Subscription Identifier
          0x11 => FOUR_BYTE,   # Session Expiry Interval
          0x12 => UTF8,        # Assigned Client Identifier
          0x13 => TWO_BYTE,    # Server Keep Alive
          0x15 => UTF8,        # Authentication Method
          0x16 => BINARY,      # Authentication Data
          0x17 => BYTE,        # Request Problem Information
          0x18 => FOUR_BYTE,   # Will Delay Interval
          0x19 => BYTE,        # Request Response Information
          0x1A => UTF8,        # Response Information
          0x1C => UTF8,        # Server Reference
          0x1F => UTF8,        # Reason String
          0x21 => TWO_BYTE,    # Receive Maximum
          0x22 => TWO_BYTE,    # Topic Alias Maximum
          0x23 => TWO_BYTE,    # Topic Alias
          0x24 => BYTE,        # Maximum QoS
          0x25 => BYTE,        # Retain Available
          0x26 => UTF8_PAIR,   # User Property
          0x27 => FOUR_BYTE,   # Maximum Packet Size
          0x28 => BYTE,        # Wildcard Subscription Available
          0x29 => BYTE,        # Subscription Identifier Available
          0x2A => BYTE         # Shared Subscription Available
        }.freeze

        # CONNACK / DISCONNECT reason codes worth naming in an operator error.
        REASON_NAMES = {
          0x00 => "Success",
          0x80 => "Unspecified error",
          0x81 => "Malformed Packet",
          0x82 => "Protocol Error",
          0x83 => "Implementation specific error",
          0x84 => "Unsupported Protocol Version",
          0x85 => "Client Identifier not valid",
          0x86 => "Bad User Name or Password",
          0x87 => "Not authorized",
          0x88 => "Server unavailable",
          0x89 => "Server busy",
          0x8A => "Banned",
          0x8C => "Bad authentication method",
          0x8F => "Topic Filter invalid",
          0x90 => "Topic Name invalid",
          0x95 => "Packet too large",
          0x97 => "Quota exceeded",
          0x99 => "Payload format invalid",
          0x9A => "Retain not supported",
          0x9B => "QoS not supported",
          0x9C => "Use another server",
          0x9D => "Server moved",
          0x9E => "Shared Subscriptions not supported",
          0x9F => "Connection rate exceeded",
          0xA1 => "Subscription Identifiers not supported",
          0xA2 => "Wildcard Subscriptions not supported"
        }.freeze

        MAX_VARIABLE_INT = 268_435_455

        module_function

        def reason_name(code)
          REASON_NAMES.fetch(code, "reason code 0x#{code.to_s(16).upcase}")
        end

        # --- variable byte integer ---------------------------------------

        def encode_variable_int(value)
          raise Error, "variable byte integer out of range: #{value}" if value.negative? || value > MAX_VARIABLE_INT

          out = +"".b
          loop do
            byte = value % 128
            value /= 128
            byte |= 0x80 if value.positive?
            out << byte
            break if value.zero?
          end
          out
        end

        # Returns [value, offset_after]. Raises on a truncated encoding or a
        # continuation bit in the 4th byte (MQTT 5 §1.5.5).
        def decode_variable_int(bytes, offset = 0)
          value = 0
          multiplier = 1
          4.times do |i|
            byte = bytes.getbyte(offset + i)
            raise Error, "malformed variable byte integer: truncated at offset #{offset}" if byte.nil?

            value += (byte & 0x7F) * multiplier
            return [value, offset + i + 1] if (byte & 0x80).zero?

            multiplier *= 128
          end
          raise Error, "malformed variable byte integer: continuation bit set in 4th byte at offset #{offset}"
        end

        # --- primitives ---------------------------------------------------

        def encode_utf8(str)
          s = str.to_s.b
          raise Error, "MQTT UTF-8 string exceeds 65535 bytes" if s.bytesize > 0xFFFF

          [s.bytesize].pack("n") + s
        end

        def encode_binary(str)
          s = str.to_s.b
          raise Error, "MQTT binary field exceeds 65535 bytes" if s.bytesize > 0xFFFF

          [s.bytesize].pack("n") + s
        end

        def read_utf8(bytes, offset)
          length = (bytes.getbyte(offset) || 0) << 8 | (bytes.getbyte(offset + 1) || 0)
          raise Error, "truncated MQTT UTF-8 string at offset #{offset}" if bytes.getbyte(offset + 1).nil? ||
                                                                             offset + 2 + length > bytes.bytesize

          [bytes.byteslice(offset + 2, length).force_encoding(Encoding::UTF_8), offset + 2 + length]
        end

        def read_binary(bytes, offset)
          length = (bytes.getbyte(offset) || 0) << 8 | (bytes.getbyte(offset + 1) || 0)
          raise Error, "truncated MQTT binary field at offset #{offset}" if bytes.getbyte(offset + 1).nil? ||
                                                                           offset + 2 + length > bytes.bytesize

          [bytes.byteslice(offset + 2, length).b, offset + 2 + length]
        end

        def read_bytes(bytes, offset, n)
          raise Error, "truncated MQTT 5 property at offset #{offset}" if offset + n > bytes.bytesize

          [bytes.byteslice(offset, n), offset + n]
        end

        # --- properties ---------------------------------------------------

        # Accepts the transport-neutral hash used by Runes::Transport::Base
        # ({response_topic:, correlation_id:, user_properties:}) or a raw
        # Array of [property_id, value] pairs (used by tests and by ids the
        # adapter does not otherwise emit).
        def normalize_property_pairs(props)
          return [] if props.nil?
          return props.map { |id, value| [id.to_i, value] } if props.is_a?(Array)

          if props.keys.any? { |key| key.is_a?(Integer) }
            props.flat_map do |id, value|
              id == 0x26 && value.is_a?(Array) ? value.map { |pair| [id, pair] } : [[id, value]]
            end
          else
            pairs = []
            pairs << [0x08, props[:response_topic]] if props[:response_topic]
            pairs << [0x09, props[:correlation_id]] if props[:correlation_id]
            (props[:user_properties] || {}).each { |k, v| pairs << [0x26, [k.to_s, v.to_s]] }
            pairs
          end
        end

        def encode_property_field(id, value)
          type = PROPERTY_TYPES[id]
          raise Error, "unknown MQTT 5 property id 0x#{id.to_s(16).upcase}" unless type

          head = encode_variable_int(id)
          case type
          when BYTE      then head + [value.to_i & 0xFF].pack("C")
          when TWO_BYTE  then head + [value.to_i & 0xFFFF].pack("n")
          when FOUR_BYTE then head + [value.to_i & 0xFFFFFFFF].pack("N")
          when VARINT    then head + encode_variable_int(value.to_i)
          when BINARY    then head + encode_binary(value)
          when UTF8      then head + encode_utf8(value)
          when UTF8_PAIR
            k, v = value.is_a?(Array) ? value : [value, ""]
            head + encode_utf8(k) + encode_utf8(v)
          end
        end

        def encode_property_fields(props)
          out = +"".b
          normalize_property_pairs(props).each { |id, value| out << encode_property_field(id, value) }
          out
        end

        # Full property block: varint length prefix + fields.
        def encode_properties(props)
          fields = encode_property_fields(props)
          encode_variable_int(fields.bytesize) + fields
        end

        # Returns [hash_of_id => value, offset_after]. Repeated User
        # Properties collect into an Array of [key, value] pairs; every other
        # id is single-valued by spec.
        def decode_properties(bytes, offset = 0)
          length, offset = decode_variable_int(bytes, offset)
          stop = offset + length
          raise Error, "MQTT 5 property block (#{length} bytes) exceeds packet" if stop > bytes.bytesize

          props = {}
          while offset < stop
            id, offset = decode_variable_int(bytes, offset)
            type = PROPERTY_TYPES[id]
            raise Error, "unknown MQTT 5 property id 0x#{id.to_s(16).upcase}" unless type

            value, offset =
              case type
              when BYTE
                [bytes.getbyte(offset), offset + 1]
              when TWO_BYTE
                raw, off = read_bytes(bytes, offset, 2)
                [raw.unpack1("n"), off]
              when FOUR_BYTE
                raw, off = read_bytes(bytes, offset, 4)
                [raw.unpack1("N"), off]
              when VARINT
                decode_variable_int(bytes, offset)
              when BINARY
                read_binary(bytes, offset)
              when UTF8
                read_utf8(bytes, offset)
              when UTF8_PAIR
                k, off = read_utf8(bytes, offset)
                v, off2 = read_utf8(bytes, off)
                [[k, v], off2]
              end
            raise Error, "truncated MQTT 5 property 0x#{id.to_s(16).upcase}" if value.nil? && type == BYTE

            if id == 0x26
              (props[id] ||= []) << value
            else
              props[id] = value
            end
          end
          raise Error, "MQTT 5 property length mismatch" unless offset == stop

          [props, offset]
        end

        # Reduce a decoded id-keyed hash to the transport-neutral subset, in
        # exactly the shape Base#reply_properties produces (empty keys
        # omitted) so publishers and subscribers agree.
        def publish_properties(props)
          out = {}
          out[:response_topic] = props[0x08] if props[0x08]
          out[:correlation_id] = props[0x09] if props[0x09]
          users = props[0x26]
          out[:user_properties] = users.to_h if users && !users.empty?
          out
        end

        # Absent 0x2A means the server supports shared subscriptions (MQTT 5
        # §3.2.2.3.13).
        def shared_available?(props)
          props.key?(0x2A) ? props[0x2A] != 0 : true
        end

        # --- packet framing -----------------------------------------------

        def packet(first_byte, body)
          body = body.b
          [first_byte].pack("C") + encode_variable_int(body.bytesize) + body
        end

        # Split a full packet. Returns [type, flags, body] or raises when the
        # declared length overruns the buffer.
        def decode_packet(bytes)
          first = bytes.getbyte(0)
          return nil if first.nil?

          length, offset = decode_variable_int(bytes, 1)
          raise Error, "MQTT 5 packet length #{length} exceeds buffer" if offset + length > bytes.bytesize

          [first >> 4, first & 0x0F, bytes.byteslice(offset, length)]
        end

        # --- CONNECT ------------------------------------------------------

        # Returns the complete CONNECT packet (fixed header included).
        # `will` is [topic, payload, retain, qos] as in the 3.1.1 adapter.
        def connect_packet(client_id:, keepalive: 30, clean_start: true, username: nil,
                           password: nil, will: nil, session_expiry: 0, properties: nil,
                           receive_maximum: nil)
          flags = 0
          flags |= 0x02 if clean_start

          payload = +"".b
          payload << encode_utf8(client_id)
          if will
            topic, will_payload, retain, will_qos = will
            will_qos = will_qos.to_i
            raise Error, "will QoS must be 0, 1 or 2 (got #{will_qos})" unless [0, 1, 2].include?(will_qos)

            flags |= 0x04 | (will_qos << 3)
            flags |= 0x20 if retain
            payload << encode_variable_int(0)          # will properties (none)
            payload << encode_utf8(topic)
            payload << encode_binary(will_payload)     # will payload is binary
          end
          if username
            flags |= 0x80
            payload << encode_utf8(username)
          end
          if password
            flags |= 0x40
            payload << encode_binary(password)
          end

          prop_pairs = normalize_property_pairs(properties)
          prop_pairs << [0x11, session_expiry.to_i] if session_expiry.to_i.positive?
          prop_pairs << [0x21, receive_maximum.to_i] if receive_maximum

          vh = encode_utf8("MQTT") + [5].pack("C") + [flags].pack("C") +
               [keepalive.to_i & 0xFFFF].pack("n") + encode_properties(prop_pairs)
          packet(0x10, vh + payload)
        end

        # body: session-present byte, reason code, properties.
        def decode_connack(body)
          raise Error, "malformed CONNACK (#{body.bytesize} bytes)" if body.bytesize < 2

          props, = body.bytesize > 2 ? decode_properties(body, 2) : [{}, 2]
          {
            session_present: (body.getbyte(0) & 0x01) == 1,
            reason_code: body.getbyte(1),
            properties: props
          }
        end

        # --- PUBLISH ------------------------------------------------------

        def publish_packet(topic:, payload:, qos: 0, retain: false, packet_id: nil,
                           properties: nil, dup: false)
          raise Error, "publish QoS 2 is not supported by the MQTT5 adapter" if qos.to_i == 2

          flags = 0
          flags |= 0x01 if retain
          flags |= (qos.to_i & 0x03) << 1
          flags |= 0x08 if dup

          body = encode_utf8(topic)
          body << [packet_id.to_i].pack("n") if qos.to_i.positive?
          body << encode_properties(properties || {})
          body << payload.to_s.b
          packet(0x30 | flags, body)
        end

        # flags are the low nibble of the fixed header.
        def decode_publish(flags, body)
          qos = (flags >> 1) & 0x03
          topic, offset = read_utf8(body, 0)
          packet_id = nil
          if qos.positive?
            packet_id = ((body.getbyte(offset) || 0) << 8) | (body.getbyte(offset + 1) || 0)
            offset += 2
          end
          props, offset = decode_properties(body, offset)
          payload = body.byteslice(offset, body.bytesize - offset) || +"".b
          {
            topic: topic,
            payload: text(payload),
            properties: publish_properties(props),
            raw_properties: props,
            qos: qos,
            retain: (flags & 0x01) != 0,
            dup: (flags & 0x08) != 0,
            packet_id: packet_id
          }
        end

        # Application payloads are UTF-8 JSON; fall back to binary only when
        # the bytes are genuinely not valid UTF-8.
        def text(bytes)
          str = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
          str.valid_encoding? ? str : str.b
        end

        # --- PUBACK / PUBREC / PUBREL / PUBCOMP ---------------------------

        def puback_packet(packet_id, reason_code: 0x00)
          packet(0x40, [packet_id.to_i].pack("n") + [reason_code & 0xFF].pack("C") + encode_variable_int(0))
        end

        def decode_puback(body)
          raise Error, "malformed PUBACK" if body.bytesize < 2

          packet_id = (body.getbyte(0) << 8) | body.getbyte(1)
          reason_code = body.bytesize > 2 ? body.getbyte(2) : 0
          [packet_id, reason_code]
        end

        # --- SUBSCRIBE / SUBACK -------------------------------------------

        # entries: [[filter, qos], ...]
        def subscribe_packet(packet_id:, entries:, properties: nil)
          body = [packet_id.to_i].pack("n") + encode_properties(properties || {})
          entries.each do |filter, qos|
            body << encode_utf8(filter) << [qos.to_i & 0x03].pack("C")
          end
          packet(0x82, body)
        end

        def decode_suback(body)
          raise Error, "malformed SUBACK" if body.bytesize < 3

          packet_id = (body.getbyte(0) << 8) | body.getbyte(1)
          props, offset = decode_properties(body, 2)
          codes = body.byteslice(offset, body.bytesize - offset).to_s.bytes
          { packet_id: packet_id, properties: props, reason_codes: codes }
        end

        # --- UNSUBSCRIBE / UNSUBACK ---------------------------------------

        def unsubscribe_packet(packet_id:, filters:, properties: nil)
          body = [packet_id.to_i].pack("n") + encode_properties(properties || {})
          Array(filters).each { |filter| body << encode_utf8(filter) }
          packet(0xA2, body)
        end

        def decode_unsuback(body)
          raise Error, "malformed UNSUBACK" if body.bytesize < 3

          packet_id = (body.getbyte(0) << 8) | body.getbyte(1)
          props, offset = decode_properties(body, 2)
          codes = body.byteslice(offset, body.bytesize - offset).to_s.bytes
          { packet_id: packet_id, properties: props, reason_codes: codes }
        end

        # --- trivial packets ----------------------------------------------

        def pingreq_packet = packet(0xC0, +"".b)
        def disconnect_packet(reason_code: 0x00)
          reason_code.zero? ? packet(0xE0, +"".b) : packet(0xE0, [reason_code].pack("C") + encode_variable_int(0))
        end
      end

      # --- adapter ----------------------------------------------------------

      SUBACK_TIMEOUT = 5.0
      # Bound the outstanding-PUBACK bookkeeping: QoS 1 publish is
      # fire-and-forget, so a broker that never acks must not grow a hash.
      MAX_PENDING_PUBACKS = 1024
      PACKET_READ_TIMEOUT = 30
      MAX_PACKET_BYTES = 16 * 1024 * 1024

      # A write that cannot complete in this long means the peer stopped
      # reading; without a deadline the shared write mutex wedges the
      # publisher AND the reader thread (T5-3).
      WRITE_TIMEOUT = 10.0
      # Reconnect backoff (T5-1). A dropped connection used to be permanent
      # and silent, which a fleet harness cannot afford.
      RECONNECT_INITIAL = 1.0
      RECONNECT_MAX = 30.0
      # If a PINGREQ is unanswered for this multiple of the keepalive, the
      # peer is gone even though the socket is still open (T5-2).
      PINGRESP_GRACE = 1.5

      attr_reader :host, :port

      def initialize(host: "127.0.0.1", port: 1883, client_id: nil, will: nil, keepalive: 30,
                     connect_timeout: 10, username: nil, password: nil, session_expiry: 0,
                     write_timeout: WRITE_TIMEOUT, reconnect: true,
                     reconnect_initial: RECONNECT_INITIAL, reconnect_max: RECONNECT_MAX,
                     on_health: nil, **options)
        super(client_id: client_id, **options)
        @host = host
        @port = port.to_i
        @will = will
        @keepalive = keepalive.to_i
        @connect_timeout = connect_timeout.to_f
        @username = username
        @password = password
        @session_expiry = session_expiry.to_i
        @socket = nil
        @reader = nil
        @connected = false
        # Absent CONNACK 0x2A means "shared subscriptions available"; only an
        # explicit 0 turns them off.
        @shared_available = true
        @write_mutex = Mutex.new
        @state_mutex = Mutex.new
        @packet_id = 0
        @pending_pubacks = {}
        @waiters = {}
        @last_write = nil
        @disconnecting = false
        @write_timeout = write_timeout.to_f
        @reconnect = reconnect ? true : false
        @reconnect_initial = reconnect_initial.to_f
        @reconnect_max = reconnect_max.to_f
        @on_health = on_health
        @last_pingreq = nil
        @awaiting_pingresp = false
        @reconnects = 0
        @last_publish_error = nil
        @puback_waiters = {}
      end

      # How many times this adapter has re-established a dropped connection;
      # the observatory/daemon can surface it instead of guessing.
      attr_reader :reconnects, :last_publish_error

      # Install/clear the health callback after construction.
      attr_writer :on_health

      def connect
        return self if @connected

        # The FIRST connect must fail loudly: a daemon that cannot reach its
        # broker at startup should not pretend to run. Once connected, the
        # reader thread takes over healing (see read_loop/reconnect!).
        open_and_handshake!
        @reader = Thread.new(@socket) { |sock| read_loop(sock) }
        @reader.name = "runes-mqtt5-reader"
        self
      end

      # Establish the TCP connection and complete CONNECT/CONNACK, leaving
      # @socket set and @connected true. Shared by #connect and #reconnect!.
      def open_and_handshake!
        socket = TCPSocket.new(@host, @port)
        begin
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        rescue StandardError
          nil
        end
        @socket = socket
        @last_write = monotonic
        @last_pingreq = nil
        @awaiting_pingresp = false

        # CONNECT is synchronous: CONNACK is read (and validated) BEFORE the
        # reader thread exists, so a rejected connect raises in the caller.
        write_packet(Codec.connect_packet(
                       client_id: @client_id, keepalive: @keepalive,
                       # A clean session only makes sense when nothing should
                       # outlive the connection.
                       clean_start: @session_expiry.zero?,
                       username: @username, password: @password, will: @will,
                       session_expiry: @session_expiry
                     ))

        packet = read_packet(socket, monotonic + @connect_timeout)
        case packet
        when nil
          raise Error, "MQTT 5 broker #{@host}:#{@port} closed the connection during CONNACK"
        when :timeout
          raise Error, "MQTT 5 CONNACK from #{@host}:#{@port} timed out after #{@connect_timeout}s"
        when :malformed, :oversized
          raise Error, "MQTT 5 broker #{@host}:#{@port} sent an unreadable CONNACK (#{packet})"
        end

        type, _flags, body = packet
        unless type == 2
          raise Error, "MQTT 5 broker #{@host}:#{@port} replied with packet type #{type}, expected CONNACK"
        end

        connack = Codec.decode_connack(body)
        # MQTT 5 success is exactly 0x00. Anything else is a refusal — and
        # note that a 3.1.1-only broker answering a CONNECT it does not
        # understand replies with the *v3* code 0x01 ("unacceptable protocol
        # version"), which must NOT be mistaken for a granted session.
        if connack[:reason_code].positive?
          raise Error, "MQTT 5 CONNACK refused: #{Codec.reason_name(connack[:reason_code])} " \
                       "(0x#{connack[:reason_code].to_s(16).upcase})"
        end

        @shared_available = Codec.shared_available?(connack[:properties])
        @connected = true
        socket
      rescue Error
        close_socket
        raise
      rescue StandardError => e
        close_socket
        raise Error, "MQTT 5 connect to #{@host}:#{@port} failed: #{e.class}: #{e.message}"
      end

      # Re-establish the connection after an unexpected drop and re-send
      # every live subscription, because the broker forgets them (unless the
      # session was resumed) and the local registry does not. Returns the new
      # socket, or nil when we were told to stop or reconnect is disabled.
      def reconnect!
        return nil if @disconnecting || !@reconnect

        delay = @reconnect_initial
        attempt = 0
        until @disconnecting
          sleep(delay)
          return nil if @disconnecting

          attempt += 1
          begin
            socket = open_and_handshake!
            resubscribe_all!
            @reconnects += 1
            health(:reconnected, attempt: attempt)
            warn "[Transport] MQTT 5 reconnected to #{@host}:#{@port} " \
                 "(attempt #{attempt}, #{subscriptions.size} subscription(s) restored)"
            return socket
          rescue Error => e
            health(:reconnect_failed, attempt: attempt, error: e.message)
            warn "[Transport] MQTT 5 reconnect attempt #{attempt} failed: #{e.message}; retrying in #{delay}s"
            delay = [delay * 2, @reconnect_max].min
          end
        end
        nil
      end

      # Re-send CONNECT'd subscriptions. Fire-and-forget on purpose: this
      # runs on the reader thread, so waiting for SUBACK would deadlock
      # against the very thread that would deliver it.
      def resubscribe_all!
        subscriptions.each do |subscription|
          wire = wire_filter(subscription)
          packet_id = next_packet_id
          write_packet(Codec.subscribe_packet(packet_id: packet_id,
                                              entries: [[wire, subscription.qos]]))
        rescue Error => e
          warn "[Transport] MQTT 5 could not restore subscription #{wire}: #{e.message}"
        end
      end

      def health(event, **details)
        @on_health&.call(event, { host: @host, port: @port, client_id: @client_id }.merge(details))
      rescue StandardError
        nil
      end

      def disconnect
        @disconnecting = true
        @connected = false
        begin
          write_packet(Codec.disconnect_packet) if @socket && !@socket.closed?
        rescue StandardError
          nil
        end
        reader = @reader
        @reader = nil
        close_socket
        reader&.kill
        reader&.join(1)
        # Release any #subscribe waiting on a SUBACK that will never arrive.
        @state_mutex.synchronize do
          @waiters.each_value { |queue| queue.push(:closed) }
          @waiters.clear
          @pending_pubacks.clear
        end
        self
      end

      def connected?
        @connected
      end

      # A reader that dies marks the adapter disconnected, so mirroring
      # #connected? is enough here and matches the 3.1.1 adapter.
      def alive?
        @connected
      end

      def publish(topic, payload, qos: 0, retain: false, properties: {})
        raise Error, "#{describe} is not connected" unless @connected
        raise ArgumentError, "MQTT5 supports QoS 0 and 1 only (QoS 2 is not implemented)" if qos.to_i == 2
        raise Error, "topic #{topic.inspect} must not contain wildcards" unless TopicFilter.valid_topic?(topic)

        qos = qos.to_i
        packet_id = qos.positive? ? next_packet_id : nil
        track_puback(packet_id) if packet_id
        write_packet(Codec.publish_packet(topic: topic, payload: payload, qos: qos, retain: retain,
                                          packet_id: packet_id, properties: properties))
        true
      rescue StandardError
        # A failed write must not leave a phantom pending id behind.
        @state_mutex.synchronize { @pending_pubacks.delete(packet_id) } if packet_id
        raise
      end

      # Like #publish, but for QoS 1 it waits for the PUBACK and raises when
      # the broker refuses the message. Callers that need to know use this;
      # #publish stays fire-and-forget for throughput.
      def publish!(topic, payload, qos: 1, retain: false, properties: {}, timeout: SUBACK_TIMEOUT)
        raise ArgumentError, "publish! needs QoS 1" unless qos.to_i == 1
        raise Error, "#{describe} is not connected" unless @connected
        raise Error, "topic #{topic.inspect} must not contain wildcards" unless TopicFilter.valid_topic?(topic)

        packet_id = next_packet_id
        waiter = Queue.new
        @state_mutex.synchronize do
          @pending_pubacks[packet_id] = monotonic
          @puback_waiters[packet_id] = waiter
        end
        begin
          write_packet(Codec.publish_packet(topic: topic, payload: payload, qos: 1, retain: retain,
                                            packet_id: packet_id, properties: properties))
          reason = wait_for(waiter, timeout, "PUBACK for #{topic}")
          if reason >= 0x80
            raise Error, "MQTT 5 broker #{@host}:#{@port} rejected PUBLISH to #{topic}: " \
                         "#{Codec.reason_name(reason)} (0x#{reason.to_s(16).upcase})"
          end

          true
        ensure
          @state_mutex.synchronize do
            @pending_pubacks.delete(packet_id)
            @puback_waiters.delete(packet_id)
          end
        end
      end

      def subscribe(filter, qos: 0, group: nil, &block)
        raise Error, "#{describe} is not connected" unless @connected
        raise ArgumentError, "a subscription needs a block" unless block
        raise ArgumentError, "MQTT5 supports QoS 0 and 1 only (QoS 2 is not implemented)" if qos.to_i == 2
        if group && !@shared_available
          raise Unsupported,
                "broker #{@host}:#{@port} says shared subscriptions are unavailable (CONNACK 0x2A = 0)"
        end

        wire = group ? TopicFilter.shared_filter(group, filter) : filter.to_s
        subscription = Subscription.new(SecureRandom.hex(6), filter.to_s, group, qos, block, self)
        # Register BEFORE SUBSCRIBE: a retained message can follow the SUBACK
        # immediately, and the reader must already be able to match it.
        register(subscription)
        packet_id = next_packet_id
        waiter = Queue.new
        @state_mutex.synchronize { @waiters[packet_id] = waiter }
        begin
          write_packet(Codec.subscribe_packet(packet_id: packet_id, entries: [[wire, qos]]))
          ack = wait_for(waiter, SUBACK_TIMEOUT, "SUBACK for #{wire}")
          code = ack[:reason_codes].first || 0x80
          if code >= 0x80
            raise Error, "MQTT 5 subscribe to #{wire} rejected: #{Codec.reason_name(code)} (0x#{code.to_s(16).upcase})"
          end
        rescue StandardError
          @mutex.synchronize { @subscriptions.delete(subscription) }
          raise
        ensure
          @state_mutex.synchronize { @waiters.delete(packet_id) }
        end
        subscription
      end

      def unsubscribe(subscription)
        return false unless subscription

        wire = wire_filter(subscription)
        # Only tell the broker when no other local subscription still needs
        # the same wire filter.
        still_needed = subscriptions.reject { |s| s.equal?(subscription) }.any? { |s| wire_filter(s) == wire }
        packet_id = nil
        if @connected && !still_needed
          begin
            packet_id = next_packet_id
            waiter = Queue.new
            @state_mutex.synchronize { @waiters[packet_id] = waiter }
            write_packet(Codec.unsubscribe_packet(packet_id: packet_id, filters: [wire]))
            wait_for(waiter, SUBACK_TIMEOUT, "UNSUBACK for #{wire}")
          rescue Error => e
            warn "[Transport] MQTT 5 unsubscribe #{wire}: #{e.message}"
          ensure
            @state_mutex.synchronize { @waiters.delete(packet_id) } if packet_id
          end
        end
        super
      end

      def supports_groups?
        @shared_available
      end

      def supports_properties?
        true
      end

      private

      def wire_filter(subscription)
        subscription.group ? TopicFilter.shared_filter(subscription.group, subscription.filter) : subscription.filter.to_s
      end

      # --- reader thread --------------------------------------------------

      # The reader owns the connection lifecycle: when a socket dies it
      # reconnects and re-subscribes (T5-1). Before this, a dropped
      # connection was permanent AND silent — `connected?` went false, nothing
      # retried, and the dispatcher (which connects once at startup) never
      # learned, so an agent simply went deaf.
      def read_loop(socket)
        loop do
          begin
            consume(socket)
          rescue StandardError => e
            # ECONNRESET, EPIPE, a malformed packet, a write deadline: every
            # one of them means "this socket is finished", not "stop
            # listening forever".
            warn "[Transport] MQTT 5 reader for #{@host}:#{@port}: #{e.class}: #{e.message}" unless @disconnecting
          end
          close_socket
          break if @disconnecting

          unless @reconnect
            health(:disconnected, reason: "reconnect disabled")
            break
          end

          health(:disconnected, reason: "connection lost")
          socket = reconnect!
          break if socket.nil?
        end
      rescue StandardError => e
        warn "[Transport] MQTT 5 reader stopped: #{e.class}: #{e.message}" unless @disconnecting
      ensure
        @connected = false
        close_socket
      end

      # Read until this connection ends. Returns normally on EOF, a stalled
      # read, an oversized/malformed packet or a lost keepalive.
      def consume(socket)
        loop do
          break unless @connected

          if pingresp_overdue?
            warn "[Transport] MQTT 5 peer #{@host}:#{@port} did not answer PINGREQ within " \
                 "#{(@keepalive * PINGRESP_GRACE).round}s; dropping connection"
            return
          end

          ready = IO.select([socket], nil, nil, select_timeout)
          if ready.nil?
            # While a PINGREQ is outstanding the select timeout IS the grace
            # deadline, so a nil here means the peer never answered.
            if @awaiting_pingresp
              warn "[Transport] MQTT 5 peer #{@host}:#{@port} never answered PINGREQ; dropping connection"
              return
            end

            # Idle long enough that the server would time the session out:
            # a PINGREQ resets its keepalive clock.
            @last_pingreq = monotonic
            @awaiting_pingresp = true
            write_packet(Codec.pingreq_packet)
            next
          end

          packet = read_packet(socket, monotonic + PACKET_READ_TIMEOUT)
          case packet
          when nil
            return
          when :timeout
            warn "[Transport] MQTT 5 read from #{@host}:#{@port} stalled mid-packet; dropping connection"
            return
          when :malformed
            warn "[Transport] MQTT 5 malformed remaining length; dropping connection"
            return
          when :oversized
            warn "[Transport] MQTT 5 packet larger than #{MAX_PACKET_BYTES} bytes; dropping connection"
            return
          else
            handle_packet(*packet)
          end
        end
      end

      # A socket that stays open while the peer stops answering is the
      # failure mode @last_write could never detect: it records OUR writes
      # (T5-2).
      def pingresp_overdue?
        return false if @keepalive.zero? || !@awaiting_pingresp
        return false if @last_pingreq.nil?

        (monotonic - @last_pingreq) > (@keepalive * PINGRESP_GRACE)
      end

      # Seconds until the reader must wake: either to send the next
      # keepalive PINGREQ, or to give up on one already outstanding. A
      # keepalive of 0 disables pings (MQTT 5 §3.1.2.10) and means "block
      # until a packet arrives".
      def select_timeout
        return nil if @keepalive.zero?

        if @awaiting_pingresp
          # Do NOT ping again while one is outstanding — that would keep
          # pushing the deadline out and hide a dead peer forever (the bug
          # doc5.md T5-2 describes).
          return [(@last_pingreq + @keepalive * PINGRESP_GRACE) - monotonic, 0].max
        end

        remaining = @keepalive - (monotonic - @last_write)
        remaining.positive? ? remaining : 0
      end

      def handle_packet(type, flags, body)
        case type
        when 3  then handle_publish(flags, body)
        when 4  then handle_puback(body)
        when 9  then handle_ack(:suback, body)
        when 11 then handle_ack(:unsuback, body)
        when 13 then @awaiting_pingresp = false # PINGRESP: the peer is alive
        when 14 then handle_server_disconnect(body)
        else warn "[Transport] MQTT 5 ignoring unexpected packet type #{type}"
        end
      end

      def handle_publish(flags, body)
        message = Codec.decode_publish(flags, body)
        if message[:qos] == 3
          # MQTT 5 §3.3.1.2 / §2.1.2: QoS 3 is a Malformed Packet and the
          # connection must be closed. Delivering it as a real message (which
          # this adapter used to do) is both wrong and unsafe.
          raise Error, "MQTT 5 malformed PUBLISH (QoS 3) from #{@host}:#{@port}; closing connection"
        end
        if message[:qos] == 2
          warn "[Transport] MQTT 5 received a QoS 2 PUBLISH; QoS 2 is not implemented, ignoring"
          return
        end
        # Ack before dispatch: a slow subscriber handler must not make the
        # broker redeliver the message.
        write_packet(Codec.puback_packet(message[:packet_id])) if message[:qos] == 1

        # Build the transport-neutral property hash through the base helper so
        # publishers and subscribers share one shape.
        raw = message[:raw_properties]
        properties = reply_properties(raw[0x08], raw[0x09], (raw[0x26] || []).to_h)

        subscriptions.each do |subscription|
          next unless TopicFilter.match?(subscription.filter, message[:topic])

          deliver(subscription, message[:topic], message[:payload], properties,
                  qos: message[:qos], retain: message[:retain])
        end
      end

      # The reason code matters: 0x87 "Not authorized" used to be deleted
      # along with the pending id, so a rejected QoS 1 PUBLISH was
      # indistinguishable from a delivered one (T5-4).
      def handle_puback(body)
        packet_id, reason = Codec.decode_puback(body)
        reason = reason.to_i
        @state_mutex.synchronize do
          @pending_pubacks.delete(packet_id)
          waiter = @puback_waiters.delete(packet_id)
          waiter&.push(reason)
        end
        return if reason < 0x80

        @last_publish_error = { packet_id: packet_id, reason_code: reason,
                                reason: Codec.reason_name(reason) }
        warn "[Transport] MQTT 5 broker #{@host}:#{@port} rejected PUBLISH #{packet_id}: " \
             "#{Codec.reason_name(reason)} (0x#{reason.to_s(16).upcase})"
      end

      def handle_ack(kind, body)
        ack = kind == :suback ? Codec.decode_suback(body) : Codec.decode_unsuback(body)
        waiter = @state_mutex.synchronize { @waiters.delete(ack[:packet_id]) }
        waiter&.push(ack)
      end

      def handle_server_disconnect(body)
        reason = body.bytesize.positive? ? body.getbyte(0) : 0
        warn "[Transport] MQTT 5 server #{@host}:#{@port} disconnected us: #{Codec.reason_name(reason)}"
        @connected = false
      end

      # --- socket IO ------------------------------------------------------

      def write_packet(bytes)
        socket = @socket
        raise Error, "#{describe} is not connected" unless socket && !socket.closed?

        @write_mutex.synchronize do
          write_with_deadline(socket, bytes)
          @last_write = monotonic
        end
        bytes
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "MQTT 5 write to #{@host}:#{@port} failed: #{e.class}: #{e.message}"
      end

      # A blocking Socket#write against a peer that stopped reading blocks
      # forever, and because PUBACK/PINGREQ share this mutex it takes the
      # reader thread with it (T5-3).
      def write_with_deadline(socket, bytes)
        deadline = monotonic + @write_timeout
        offset = 0
        while offset < bytes.bytesize
          remaining = deadline - monotonic
          if remaining <= 0
            raise Error, "MQTT 5 write to #{@host}:#{@port} timed out after #{@write_timeout}s " \
                         "(peer stopped reading?)"
          end

          ready = IO.select(nil, [socket], nil, remaining)
          if ready.nil?
            raise Error, "MQTT 5 write to #{@host}:#{@port} timed out after #{@write_timeout}s " \
                         "(peer stopped reading?)"
          end

          written =
            begin
              socket.write_nonblock(bytes.byteslice(offset, bytes.bytesize - offset), exception: false)
            rescue IOError, SystemCallError => e
              raise Error, "MQTT 5 write to #{@host}:#{@port} failed: #{e.class}: #{e.message}"
            end

          case written
          when :wait_writable then next
          when nil then raise Error, "MQTT 5 socket to #{@host}:#{@port} closed during write"
          else offset += written
          end
        end
        offset
      end

      # One packet: fixed header + remaining length + body, against a
      # monotonic deadline. Returns [type, flags, body], nil on EOF, or a
      # symbol for the protocol failures the caller must act on.
      def read_packet(io, deadline)
        header = read_exact(io, 1, deadline)
        return header unless header.is_a?(String)

        first = header.getbyte(0)
        multiplier = 1
        length = 0
        continuation = false
        4.times do
          raw = read_exact(io, 1, deadline)
          return raw unless raw.is_a?(String)

          byte = raw.getbyte(0)
          length += (byte & 0x7F) * multiplier
          multiplier *= 128
          continuation = (byte & 0x80) != 0
          break unless continuation
        end
        return :malformed if continuation
        return :oversized if length > MAX_PACKET_BYTES

        body = length.positive? ? read_exact(io, length, deadline) : +"".b
        return body unless body.is_a?(String)

        [first >> 4, first & 0x0F, body]
      end

      # IO.select + readpartial so a silent peer cannot pin this thread and
      # a partial packet is still reassembled correctly.
      def read_exact(io, n, deadline)
        buf = +"".b
        while buf.bytesize < n
          if deadline
            remaining = deadline - monotonic
            return :timeout if remaining <= 0
            return :timeout if IO.select([io], nil, nil, remaining).nil?
          end
          buf << io.readpartial([n - buf.bytesize, 65_536].min)
        end
        buf
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EBADF, IOError
        nil
      end

      def close_socket
        @state_mutex.synchronize { @puback_waiters.each_value { |q| q.push(:closed) }; @puback_waiters.clear }
        @socket&.close
      rescue StandardError
        nil
      ensure
        @socket = nil
      end

      # --- bookkeeping ----------------------------------------------------

      def next_packet_id
        @state_mutex.synchronize do
          loop do
            @packet_id = (@packet_id % 65_535) + 1
            break unless @pending_pubacks.key?(@packet_id) || @waiters.key?(@packet_id)
          end
          @packet_id
        end
      end

      def track_puback(packet_id)
        @state_mutex.synchronize do
          @pending_pubacks[packet_id] = monotonic
          @pending_pubacks.delete(@pending_pubacks.first[0]) while @pending_pubacks.size > MAX_PENDING_PUBACKS
        end
      end

      def wait_for(waiter, timeout, what)
        case (value = waiter.pop(timeout: timeout))
        when :closed then raise Error, "#{describe} disconnected while waiting for #{what}"
        when nil     then raise Error, "timed out waiting for MQTT 5 #{what} after #{timeout}s"
        else value
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
