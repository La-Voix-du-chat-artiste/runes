require "test_helper"

# doc5.md O2.3: the page that shows what was *refused*. It is read-only, so
# these tests are about what it can tell an operator, not about side effects.
class SecurityControllerTest < ActionDispatch::IntegrationTest
  setup do
    Packet.delete_all
    @denial = denial("run_command", "exec", "/etc/passwd", "runes-alpha", 5.minutes.ago)
    @denial2 = denial("write_file", "fs_write", "config/.env", "runes-beta", 2.hours.ago)
    denial("run_command", "exec", "rm -rf /", nil, 30.hours.ago) # outside the 24 h window
  end

  test "the page counts refusals and shows who was refused what" do
    get security_path

    assert_response :success
    assert_match "Security", response.body
    assert_match "refusals / hour", response.body
    assert_match "run_command", response.body
    assert_match "write_file", response.body
    assert_match "/etc/passwd", response.body
    # The third denial is outside the 24-hour window: it is counted all-time,
    # not in the window tables.
    assert_match "refusals observed", response.body
  end

  test "each refusal links to the packet that recorded it" do
    get security_path

    assert_match packet_path(@denial), response.body
    assert_match packet_path(@denial2), response.body
  end

  test "the filters narrow by tool and by agent" do
    get security_path(tool: "write_file")
    assert_match "write_file", response.body
    refute_match "/etc/passwd", response.body

    get security_path(agent_id: "runes-alpha")
    assert_match "/etc/passwd", response.body
    refute_match "config/.env", response.body
  end

  test "a filter that matches nothing says so instead of looking broken" do
    get security_path(tool: "never_used")

    assert_response :success
    assert_match "matches these filters", response.body
  end

  test "an empty page explains what would put something on it" do
    Packet.delete_all

    get security_path

    assert_response :success
    assert_match "No refusal", response.body
    assert_match "runes/guard/denied", response.body
    assert_match "RUNES_WORKFLOW_POLICY", response.body
  end

  # Who published and what was refused are the two halves of one question, so
  # they share a page.
  test "the page carries the signature verdicts and impersonation findings" do
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   agent_id: "runes-alpha", signature_state: "verified",
                   key_fingerprint: "aa" * 32, occurred_at: 10.minutes.ago, received_at: 10.minutes.ago)
    Packet.create!(topic: "runes/prompts", kind: "prompt", payload: "{}", payload_bytes: 2,
                   agent_id: "runes-alpha", signature_state: "untrusted",
                   key_fingerprint: "bb" * 32, occurred_at: 10.minutes.ago, received_at: 10.minutes.ago)

    get security_path

    assert_response :success
    assert_match "Published identity", response.body
    assert_match "2 different keys", response.body
    assert_match "runes-alpha", response.body
  end

  test "the layout links to the security page" do
    get root_path

    assert_response :success
    assert_match security_path, response.body
  end

  private

  def denial(tool, action, resource, agent, at)
    Packet.create!(
      topic: "runes/guard/denied", kind: "guard_denied", payload_bytes: 100,
      payload: JSON.generate("tool" => tool, "action" => action, "resource" => resource,
                             "decision" => "denied", "agent" => agent),
      tool: tool, event: action, agent_id: agent, occurred_at: at, received_at: at
    )
  end
end
