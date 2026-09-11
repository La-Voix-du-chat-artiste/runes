require "test_helper"

class PacketsControllerTest < ActionDispatch::IntegrationTest
  test "index renders the packet log" do
    get packets_path

    assert_response :success
    assert_match "runes/prompts/req-1/progress", response.body
    assert_match "Packet log", response.body
  end

  test "index honours the kind filter" do
    get packets_path(kind: "progress")

    assert_response :success
    assert_match "plan_ready", response.body
    assert_no_match(%r{runes/prompts/req-1/response}, response.body)
  end

  test "index honours the agent filter and hides the agent column" do
    get packets_path(agent_id: "runes-beta")

    assert_response :success
    assert_match "runes/agents/runes-beta/tasks/req-2/response", response.body
    assert_no_match(%r{runes/prompts/req-1/progress}, response.body)
  end

  test "index honours the payload search" do
    get packets_path(q: "greeting file")

    assert_response :success
    assert_match "runes/prompts", response.body
    assert_no_match(%r{runes/agents/runes-beta/tasks/req-2/response}, response.body)
  end

  # O5-6: `%` and `_` are LIKE metacharacters; unescaped, q=% scanned and
  # matched every row.
  test "payload search escapes LIKE metacharacters" do
    Packet.create!(topic: "runes/prompts/response", kind: "response", payload: "abc%def",
                   payload_bytes: 7, occurred_at: Time.current, received_at: Time.current)
    Packet.create!(topic: "runes/prompts/response", kind: "response", payload: "abcdef",
                   payload_bytes: 6, occurred_at: Time.current, received_at: Time.current)

    get packets_path(q: "c%d")
    assert_response :success
    assert_match "abc%def", response.body
    assert_no_match(/abcdef/, response.body)

    get packets_path(q: "%")
    assert_response :success
    assert_match "abc%def", response.body
    assert_no_match(/write a greeting file/, response.body)
  end

  test "feed returns rendered rows and the cursor" do
    last_id = Packet.maximum(:id)

    get feed_path(after_id: 0), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal last_id, body["last_id"]
    assert_equal Packet.count, body["packets"].size
    assert_match "details class=\"packet\"", body["packets"].first["html"]
    assert_equal Packet.count, body["stats"]["total"]
  end

  test "feed only returns packets after the cursor and applies filters" do
    first_id = Packet.order(:id).first.id

    get feed_path(after_id: first_id, agent_id: "runes-alpha"), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_operator body["packets"].size, :>=, 1
    assert(body["packets"].all? { |packet| packet["id"] > first_id })
    assert_match "runes-alpha", body["packets"].first["html"]
  end

  # O5-2 regression: whole 256 KiB payloads used to ship on every poll.
  test "feed serves a bounded summary for huge packets" do
    payload = "z" * 64.kilobytes
    now = Time.current
    Packet.insert_all(
      120.times.map do |i|
        { topic: "runes/tools/echo/response", payload: payload, payload_bytes: payload.bytesize,
          truncated: false, scrubbed: false, kind: "tool_response", event: nil, tool: "echo",
          occurred_at: now, received_at: now, created_at: now, updated_at: now,
          agent_id: "runes-big-#{i}" }
      end
    )

    get feed_path(after_id: 0), as: :json

    assert_response :success
    assert_operator response.body.bytesize, :<, 1.megabyte,
                    "a page of 64 KiB payloads must not ship whole"
    body = JSON.parse(response.body)
    assert_operator body["packets"].size, :>=, 120
  end

  # The full body is one explicit request away.
  test "show returns the full payload on demand" do
    payload = "q" * 64.kilobytes
    packet = Packet.create!(topic: "runes/tools/echo/response", kind: "tool_response",
                            payload: payload, payload_bytes: payload.bytesize,
                            occurred_at: Time.current, received_at: Time.current)

    get packet_path(packet)

    assert_response :success
    assert_operator response.body.bytesize, :>, 64.kilobytes
    assert_match "runes/tools/echo/response", response.body
  end

  # MQTT 5 properties are worth storing only if a human can see them: the
  # packet page names the reply target and every user property (doc5.md O0.1).
  test "show renders the MQTT 5 properties the transport carried" do
    packet = Packet.create!(topic: "runes/a2a/tasks/agent-7", kind: "task", payload: "{}",
                            payload_bytes: 2, occurred_at: Time.current, received_at: Time.current,
                            qos: 1, retain: true, correlation_id: "corr-42",
                            response_topic: "runes/a2a/replies/9",
                            user_properties: JSON.generate("a2a-status" => "working"))

    get packet_path(packet)

    assert_response :success
    assert_match "corr-42", response.body
    assert_match "runes/a2a/replies/9", response.body
    assert_match "a2a-status", response.body
    assert_match "retained", response.body

    # The list row is the same partial: the property must be legible there
    # too, without expanding the packet.
    get packets_path
    assert_response :success
    assert_match "a2a-status", response.body
    assert_match "corr-42", response.body
  end

  # The dead /feed/stats endpoint was removed (O5-7).
  test "the removed feed stats route is gone" do
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/feed/stats") }
  end
  # O0.3: the verdict is on the page, with the fingerprint and a plain-English
  # reason — an unsigned packet is labelled, not silently trusted.
  test "show renders the signature verdict and the signing key" do
    packet = Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                            occurred_at: Time.current, received_at: Time.current,
                            agent_id: "runes-alpha", signature_state: "untrusted",
                            key_fingerprint: "ab" * 32)

    get packet_path(packet)

    assert_response :success
    assert_match "untrusted", response.body
    assert_match "ab" * 16, response.body
    assert_match "trust store has no key", response.body
  end

  test "an unsigned packet says so on its page" do
    packet = Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                            occurred_at: Time.current, received_at: Time.current,
                            signature_state: "unsigned")

    get packet_path(packet)

    assert_response :success
    assert_match "no signature", response.body
  end

  # The list is where a suspicious packet is first seen, so a signed one is
  # badged there without expanding it.
  test "the packet list badges signed packets only" do
    Packet.delete_all
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   occurred_at: Time.current, received_at: Time.current,
                   signature_state: "verified", key_fingerprint: "cd" * 32)
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   occurred_at: Time.current, received_at: Time.current,
                   signature_state: "unsigned")

    get packets_path

    assert_response :success
    assert_match "badge--sig-verified", response.body
    refute_match "badge--sig-unsigned", response.body
  end
end
