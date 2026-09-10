# Hermetic unit tests for the MQTT 5 packet codec and the adapter's
# no-network surface. Deliberately does NOT require test_helper: that loads
# the dispatcher (under concurrent edit) and the whole harness, none of which
# the wire format depends on.
#
#   bundle exec ruby -Ilib -Itest test/mqtt5_codec_test.rb
require "minitest/autorun"
require_relative "../lib/runes/transport/mqtt5"

class MQTT5CodecTest < Minitest::Test
  C = Runes::Transport::MQTT5::Codec
  Err = Runes::Transport::Error

  # --- variable byte integer ---------------------------------------------

  def test_variable_int_encode_boundaries
    assert_equal [0x00],             C.encode_variable_int(0).bytes
    assert_equal [0x7F],             C.encode_variable_int(127).bytes
    assert_equal [0x80, 0x01],       C.encode_variable_int(128).bytes
    assert_equal [0xFF, 0x7F],       C.encode_variable_int(16_383).bytes
    assert_equal [0x80, 0x80, 0x01], C.encode_variable_int(16_384).bytes
    assert_equal [0xFF, 0xFF, 0x7F], C.encode_variable_int(2_097_151).bytes
    assert_equal [0x80, 0x80, 0x80, 0x01], C.encode_variable_int(2_097_152).bytes
    assert_equal [0xFF, 0xFF, 0xFF, 0x7F], C.encode_variable_int(268_435_455).bytes
  end

  def test_variable_int_decode_round_trip_and_offset
    [0, 1, 127, 128, 300, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455].each do |value|
      encoded = C.encode_variable_int(value)
      decoded, offset = C.decode_variable_int(encoded)
      assert_equal value, decoded, "round trip #{value}"
      assert_equal encoded.bytesize, offset
    end
    # Offset is honoured and the tail is left alone.
    value, offset = C.decode_variable_int("\xAA\x80\x01\xBB".b, 1)
    assert_equal 128, value
    assert_equal 3, offset
  end

  def test_variable_int_malformed_input
    err = assert_raises(Err) { C.decode_variable_int("\x80\x80\x80\x80".b) }
    assert_match(/continuation bit/, err.message)

    assert_raises(Err) { C.decode_variable_int("\x80".b) }
    assert_raises(Err) { C.decode_variable_int("\xFF\xFF\xFF".b) }
    assert_raises(Err) { C.encode_variable_int(-1) }
    assert_raises(Err) { C.encode_variable_int(268_435_456) }
  end

  # --- properties --------------------------------------------------------

  def test_properties_round_trip_for_runes_subset
    bytes = C.encode_properties(
      response_topic: "runes/reply",
      correlation_id: "corr-\x00\x01".b,
      user_properties: { "trace" => "abc123", "a2a-status" => "ok" }
    )
    props, offset = C.decode_properties(bytes)
    assert_equal bytes.bytesize, offset
    assert_equal "runes/reply", props[0x08]
    assert_equal "corr-\x00\x01".b, props[0x09]
    assert_equal [["trace", "abc123"], ["a2a-status", "ok"]], props[0x26]

    # And the transport-neutral projection the adapter hands to Message.
    assert_equal({ response_topic: "runes/reply", correlation_id: "corr-\x00\x01".b,
                   user_properties: { "trace" => "abc123", "a2a-status" => "ok" } },
                 C.publish_properties(props))
  end

  def test_empty_properties_round_trip
    bytes = C.encode_properties({})
    assert_equal "\x00".b, bytes
    props, offset = C.decode_properties(bytes)
    assert_equal({}, props)
    assert_equal 1, offset
    assert_equal({}, C.publish_properties(props))
  end

  # An id Runes does not consume must still be skipped with the right width,
  # otherwise the 0x08/0x26 properties that FOLLOW it would be misparsed.
  def test_skips_unknown_but_known_type_properties
    fields = +"".b
    fields << C.encode_property_field(0x2A, 1)                # BYTE
    fields << C.encode_property_field(0x02, 3600)             # FOUR_BYTE
    fields << C.encode_property_field(0x13, 30)               # TWO_BYTE
    fields << C.encode_property_field(0x0B, 200_000)          # variable byte int
    fields << C.encode_property_field(0x1F, "server says hi") # UTF8
    fields << C.encode_property_field(0x16, "\xDE\xAD".b)     # BINARY
    fields << C.encode_property_field(0x26, %w[k v])          # UTF8 pair
    fields << C.encode_property_field(0x08, "after/all/that")
    fields << C.encode_property_field(0x09, "cid")

    props, offset = C.decode_properties(C.encode_variable_int(fields.bytesize) + fields)
    assert_equal fields.bytesize + 1, offset
    assert_equal 1, props[0x2A]
    assert_equal 3600, props[0x02]
    assert_equal 30, props[0x13]
    assert_equal 200_000, props[0x0B]
    assert_equal "server says hi", props[0x1F]
    assert_equal "\xDE\xAD".b, props[0x16]
    assert_equal [%w[k v]], props[0x26]
    assert_equal "after/all/that", props[0x08]
    assert_equal "cid", props[0x09]
  end

  def test_unknown_property_id_raises
    fields = C.encode_property_field(0x08, "ok") + C.encode_variable_int(0x7F) + "\x00".b
    block = C.encode_variable_int(fields.bytesize) + fields
    err = assert_raises(Err) { C.decode_properties(block) }
    assert_match(/unknown MQTT 5 property id 0x7F/i, err.message)
  end

  def test_truncated_property_block_raises
    # Declares 10 bytes of properties but only supplies 1.
    assert_raises(Err) { C.decode_properties("\x0A\x2A".b) }
    # A UTF-8 property that runs off the end of the block.
    assert_raises(Err) { C.decode_properties("\x04\x08\x00\x05ab".b) }
  end

  def test_shared_available_semantics
    assert C.shared_available?({})          # absent means available
    assert C.shared_available?({ 0x2A => 1 })
    refute C.shared_available?({ 0x2A => 0 })
  end

  # --- CONNECT -----------------------------------------------------------

  def test_connect_packet_minimal_exact_bytes
    packet = C.connect_packet(client_id: "cid", keepalive: 60, clean_start: true)
    expected = "\x10\x10".b +
               "\x00\x04MQTT".b + "\x05".b + "\x02".b + "\x00\x3C".b + "\x00".b +
               "\x00\x03cid".b
    assert_equal expected, packet
  end

  def test_connect_packet_with_username_password_and_will_exact_bytes
    packet = C.connect_packet(client_id: "cid", keepalive: 30, clean_start: true,
                              username: "u", password: "p",
                              will: ["w/t", "bye", true, 1], session_expiry: 0)
    expected = "\x10\x21".b +
               "\x00\x04MQTT".b + "\x05".b + "\xEE".b + "\x00\x1E".b + "\x00".b +
               "\x00\x03cid".b +
               "\x00".b +                       # will properties
               "\x00\x03w/t".b + "\x00\x03bye".b +
               "\x00\x01u".b + "\x00\x01p".b
    assert_equal expected, packet

    # Connect flags: user(0x80) | pass(0x40) | will-retain(0x20) | will-qos1(0x08) | will(0x04) | clean(0x02)
    assert_equal 0xEE, packet.getbyte(9)
  end

  def test_connect_packet_session_expiry_property
    packet = C.connect_packet(client_id: "cid", keepalive: 30, clean_start: false, session_expiry: 300)
    assert_includes packet, "\x11\x00\x00\x01\x2C".b
    # clean_start false -> bit 1 clear; session expiry property present.
    assert_equal 0x00, packet.getbyte(9)
  end

  def test_connect_packet_rejects_bad_will_qos
    assert_raises(Err) { C.connect_packet(client_id: "c", will: ["t", "p", false, 3]) }
  end

  # --- CONNACK -----------------------------------------------------------

  def test_decode_connack_fixture
    # session_present=0, reason=0x00, props: 0x2A=1, 0x21=20, 0x13=30
    body = "\x00\x00\x08\x2A\x01\x21\x00\x14\x13\x00\x1E".b
    full = "\x20\x0B".b + body

    type, flags, decoded_body = C.decode_packet(full)
    assert_equal 2, type
    assert_equal 0, flags
    assert_equal body, decoded_body

    ack = C.decode_connack(decoded_body)
    refute ack[:session_present]
    assert_equal 0x00, ack[:reason_code]
    assert_equal 1, ack[:properties][0x2A]
    assert_equal 20, ack[:properties][0x21]
    assert_equal 30, ack[:properties][0x13]
    assert C.shared_available?(ack[:properties])
  end

  def test_decode_connack_without_shared_property_means_available
    ack = C.decode_connack("\x01\x00\x00".b)
    assert ack[:session_present]
    assert_equal({}, ack[:properties])
    assert C.shared_available?(ack[:properties])
  end

  def test_decode_connack_reports_shared_unavailable_and_refusal
    ack = C.decode_connack("\x00\x00\x02\x2A\x00".b)
    refute C.shared_available?(ack[:properties])
    assert_equal "Shared Subscriptions not supported", C.reason_name(0x9E)
    assert_equal "Not authorized", C.reason_name(0x87)
    assert_equal "reason code 0x7F", C.reason_name(0x7F)
  end

  # --- SUBSCRIBE / SUBACK ------------------------------------------------

  def test_subscribe_packet_exact_bytes_single_entry
    packet = C.subscribe_packet(packet_id: 1, entries: [["a/b", 1]])
    assert_equal "\x82\x09\x00\x01\x00\x00\x03a/b\x01".b, packet
  end

  def test_subscribe_packet_exact_bytes_shared_group
    packet = C.subscribe_packet(packet_id: 0x0002, entries: [["$share/workers/a/+", 1]])
    expected = "\x82\x18".b +
               "\x00\x02".b + "\x00".b +
               "\x00\x12$share/workers/a/+".b + "\x01".b
    assert_equal expected, packet
    # No Local must stay 0 for shared subscriptions; only QoS is set.
    assert_equal 0x01, packet.getbyte(packet.bytesize - 1)
  end

  def test_subscribe_packet_multiple_entries
    packet = C.subscribe_packet(packet_id: 7, entries: [["a", 0], ["b/#", 1]])
    assert_equal "\x82\x0D\x00\x07\x00\x00\x01a\x00\x00\x03b/#\x01".b, packet
  end

  def test_decode_suback_fixture
    # packet_id=1, props len 0, reason codes [0x00, 0x01]
    full = "\x90\x05\x00\x01\x00\x00\x01".b
    type, flags, body = C.decode_packet(full)
    assert_equal 9, type
    assert_equal 0, flags
    ack = C.decode_suback(body)
    assert_equal 1, ack[:packet_id]
    assert_equal({}, ack[:properties])
    assert_equal [0x00, 0x01], ack[:reason_codes]
  end

  def test_decode_suback_failure_codes
    full = "\x90\x04\x00\x09\x00\x9E".b
    _type, _flags, body = C.decode_packet(full)
    ack = C.decode_suback(body)
    assert_equal 0x9E, ack[:reason_codes].first
    assert ack[:reason_codes].first >= 0x80
  end

  # --- PUBLISH -----------------------------------------------------------

  def test_decode_publish_with_properties_fixture
    body = +"".b
    body << "\x00\x01t".b                          # topic "t"
    body << "\x00\x07".b                           # packet id 7 (QoS 1)
    body << "\x0F".b                               # property length 15
    body << "\x08\x00\x01r".b                      # Response Topic "r"
    body << "\x09\x00\x01c".b                      # Correlation Data "c"
    body << "\x26\x00\x01k\x00\x01v".b             # User Property k=v
    body << "hello".b
    full = "\x32\x1A".b + body                      # qos1 flags

    type, flags, decoded_body = C.decode_packet(full)
    assert_equal 3, type
    assert_equal 0x02, flags

    message = C.decode_publish(flags, decoded_body)
    assert_equal "t", message[:topic]
    assert_equal "hello", message[:payload]
    assert_equal 1, message[:qos]
    assert_equal 7, message[:packet_id]
    refute message[:retain]
    refute message[:dup]
    assert_equal({ response_topic: "r", correlation_id: "c", user_properties: { "k" => "v" } },
                 message[:properties])
  end

  def test_decode_publish_without_properties_qos0
    full = "\x30\x07".b + "\x00\x03a/b".b + "\x00".b + "x".b
    type, flags, body = C.decode_packet(full)
    assert_equal 3, type
    message = C.decode_publish(flags, body)
    assert_equal "a/b", message[:topic]
    assert_equal "x", message[:payload]
    assert_equal 0, message[:qos]
    assert_nil message[:packet_id]
    assert_equal({}, message[:properties])
  end

  def test_decode_publish_retain_and_dup_flags
    # retain|dup|qos1, so a packet id must be present.
    full = "\x3B\x09".b + "\x00\x03a/b".b + "\x00\x09".b + "\x00".b + "x".b
    _type, flags, body = C.decode_packet(full)
    message = C.decode_publish(flags, body)
    assert message[:retain]
    assert message[:dup]
    assert_equal 1, message[:qos]
    assert_equal 9, message[:packet_id]
  end

  def test_publish_packet_exact_bytes
    assert_equal "\x30\x07\x00\x03a/b\x00x".b,
                 C.publish_packet(topic: "a/b", payload: "x", qos: 0)

    packet = C.publish_packet(topic: "t", payload: "hi", qos: 1, retain: true,
                              packet_id: 7, properties: { response_topic: "r" })
    expected = "\x33\x0C".b + "\x00\x01t".b + "\x00\x07".b + "\x04\x08\x00\x01r".b + "hi".b
    assert_equal expected, packet

    assert_raises(Err) { C.publish_packet(topic: "t", payload: "x", qos: 2) }
  end

  def test_utf8_and_binary_encoders_guard_length
    assert_equal "\x00\x03abc".b, C.encode_utf8("abc")
    assert_equal "\x00\x04\xF0\x9F\x94\xA5".b, C.encode_utf8("\u{1F525}")
    assert_raises(Err) { C.encode_utf8("x" * 65_536) }
    assert_raises(Err) { C.encode_binary("x" * 65_536) }
  end

  # --- PUBACK / framing / control packets --------------------------------

  def test_puback_round_trip
    packet = C.puback_packet(0x1234)
    type, flags, body = C.decode_packet(packet)
    assert_equal 4, type
    assert_equal 0x40, packet.getbyte(0)
    assert_equal 0, flags
    packet_id, reason = C.decode_puback(body)
    assert_equal 0x1234, packet_id
    assert_equal 0x00, reason
  end

  def test_control_packets
    assert_equal "\xC0\x00".b, C.pingreq_packet
    assert_equal "\xE0\x00".b, C.disconnect_packet
  end

  def test_decode_packet_rejects_overrun
    assert_raises(Err) { C.decode_packet("\x30\x0A\x00\x01".b) }
  end

  def test_unsubscribe_packet_and_unsuback
    packet = C.unsubscribe_packet(packet_id: 3, filters: ["$share/g/a/+"])
    expected = "\xA2\x11".b + "\x00\x03".b + "\x00".b + "\x00\x0C$share/g/a/+".b
    assert_equal expected, packet

    type, _flags, body = C.decode_packet(packet)
    assert_equal 10, type
    ack = C.decode_unsuback("\x00\x03\x00\x00".b)
    assert_equal 3, ack[:packet_id]
    assert_equal [0x00], ack[:reason_codes]
  end

  # --- adapter surface (no socket) --------------------------------------

  def test_adapter_exposes_required_api_without_connecting
    transport = Runes::Transport::MQTT5.new(host: "example.invalid", port: 1883, client_id: "c-1")
    assert_equal "example.invalid", transport.host
    assert_equal 1883, transport.port
    refute transport.connected?
    refute transport.alive?
    assert transport.supports_properties?
    # Undecided before CONNACK; absent 0x2A means available.
    assert transport.supports_groups?
    assert_kind_of Runes::Transport::Base, transport
  end

  def test_adapter_publish_before_connect_raises_transport_error
    transport = Runes::Transport::MQTT5.new(host: "example.invalid", port: 1883, client_id: "c-2")
    err = assert_raises(Runes::Transport::Error) { transport.publish("a", "b") }
    assert_match(/not connected/, err.message)
  end

  def test_adapter_disconnect_without_connect_is_quiet
    transport = Runes::Transport::MQTT5.new(host: "example.invalid", port: 1883, client_id: "c-3")
    assert_same transport, transport.disconnect
    refute transport.connected?
  end
end
