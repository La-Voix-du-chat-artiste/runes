require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Mode commands (goal/plan/mission/build) on the dispatcher plus the
# TUI's local slash-command parser.
class TestModeCommands < Minitest::Test
  def setup
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)

    @tmp = Dir.mktmpdir('modes-root')
    ENV['RUNES_WORKSPACE'] = File.join(@tmp, 'workspace')
    @settings = Runes::Core::Settings.new(root: @tmp)
    @tools = Dir.mktmpdir('modes-tools')
    @agents = []
  end

  def teardown
    @threads&.each(&:kill)
    @broker_thread&.kill
    [@tmp, @tools].each { |d| FileUtils.remove_entry(d) if d && Dir.exist?(d) }
    ENV.delete('RUNES_WORKSPACE')
  end

  class PublishingClient
    def initialize(broker)
      @broker = broker
    end

    def publish(topic, payload, retain: false)
      @broker.publish(topic, payload, retain: retain)
    end
  end

  class StubLLM
    def initialize(content = '{"steps":[]}')
      @content = content
    end

    def call(_prompt, **)
      { ok: true, mode: :content, content: @content, raw: {} }
    end

    def chat(_messages, **)
      { ok: true, mode: :content, content: 'reflection? question?', raw: {} }
    end
  end

  def make_dispatcher(agent_id)
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: RecordingTransport.new
    )
    @agents << d
    d
  end

  def envelope(mode, prompt, **kw)
    {
      request_id: kw.fetch(:request_id, "req-#{rand(100_000)}"),
      prompt: prompt, mode: mode, session_id: kw[:session_id],
      control: kw[:control], epic_path: kw[:epic_path],
      mission_path: kw[:mission_path], from_envelope: true
    }
  end

  # --- goal/plan session hygiene ---------------------------------------

  # The session id (SessionStore) is what keeps goal/plan turns on one
  # conversation; the MQTT claim/lease topics that named it were deleted in
  # 0.3.0 (doc5.md X5-1), so nothing here relies on them any more.

  # D2: a crashed agent's stale session must not stand down survivors on
  # later turns of the same session.
  # D4: two identical prompts in the window must not both execute.
  # --- session store hygiene --------------------------------------------

  def test_goal_turns_open_and_close_sessions
    d = make_dispatcher('mode-sess')
    d.instance_variable_set(:@llm, StubLLM.new)
    d.handle_payload(
                    JSON.generate('mode' => 'goal', 'session_id' => 's-open', 'prompt' => 'idea', 'request_id' => 's1'))
    assert d.instance_variable_get(:@sessions).key?('s-open')
    refute_nil d.instance_variable_get(:@sessions)['s-open'][:last_turn_at]
  end

  def test_idle_session_is_pruned_after_ttl
    d = make_dispatcher('mode-prune')
    d.instance_variable_set(:@llm, StubLLM.new)
    sid = 's-old'
    d.handle_payload(
                    JSON.generate('mode' => 'goal', 'session_id' => sid, 'prompt' => 'x', 'request_id' => 's2'))
    refute_nil d.instance_variable_get(:@sessions)[sid]
    d.instance_variable_get(:@sessions)[sid][:opened_at] = Time.now - 9999
    d.handle_payload(
                    JSON.generate('mode' => 'goal', 'session_id' => 's-fresh9', 'prompt' => 'after the ttl', 'request_id' => 's3'))
    assert_nil d.instance_variable_get(:@sessions)[sid], 'idle session pruned'
  end

  # D8: a /done without a session id can finalize when the daemon holds
  # exactly one open goal session (one-shot CLI flows).
  def test_done_without_session_id_uses_sole_open_session
    d = make_dispatcher('mode-oneshot')
    chat = Object.new
    chat.define_singleton_method(:chat) do |_msgs, **|
      { ok: true, mode: :content,
        content: "# Epic: x\n## Problem\np\n## Target users\nt\n## Goals\ng\n## Non-goals\nn\n## Success criteria\ns\n## Constraints & assumptions\nc\n## Open questions\no", raw: {} }
    end
    d.instance_variable_set(:@llm, chat)
    d.handle_payload(
                    JSON.generate('mode' => 'goal', 'session_id' => 's-only', 'prompt' => 'build a thing', 'request_id' => 's4'))
    replied = []
    d.define_singleton_method(:publish_result) { |_c, _t, s| replied << s }
    d.handle_payload(
                    JSON.generate('mode' => 'goal', 'control' => 'done', 'prompt' => '', 'request_id' => 's5'))
    assert replied.any? { |s| s.include?('Epic written') },
           '/done without a session id should finalize the sole open session'
  end

  # --- plan mode --------------------------------------------------------

  def test_plan_mode_requires_an_epic_or_text
    d = make_dispatcher('mode-plan')
    replied = []
    d.define_singleton_method(:publish_result) { |_c, _t, s| replied << s }
    d.handle_payload(
                    JSON.generate('mode' => 'plan', 'prompt' => '', 'request_id' => 'p1'))
    assert replied.any? { |s| s.include?('No epic available') }
  end

  # --- TUI command parser ----------------------------------------------------------

  def test_tui_slash_commands_never_publish_prompt_text
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999, root: Dir.mktmpdir('tui-empty'))
    published = []
    tui.define_singleton_method(:publish_envelope) do |fields|
      published << fields
      fields['request_id'] || "stub-#{published.size}"
    end

    tui.handle_line('/goal I want a pomodoro')
    assert_equal 'goal', published.last['mode']
    refute_nil published.last['session_id']

    tui.handle_line('make it beep') # plain line during goal -> continues session
    assert_equal 'goal', published.last['mode']
    assert_equal 'make it beep', published.last['prompt']

    tui.handle_line('/done')
    assert_equal 'done', published.last['control']
    # T2: the pending id is the request id /done published with (set
    # BEFORE the publish, never the other way around).
    assert_equal published.last['request_id'], tui.instance_variable_get(:@pending_done_req)
    # /done no longer drops to build immediately: the session stays open
    # until the epic_written (or error) event arrives.
    assert_equal :goal, tui.instance_variable_get(:@mode)

    tui.handle_line('/plan') # no epic yet -> local goal switch, no publish
    assert_equal 3, published.size
    assert_equal :goal, tui.instance_variable_get(:@mode)

    tui.handle_line('/warp 9')
    assert_equal 3, published.size, 'unknown command must not publish'

    tui.handle_line('/help')
    assert_equal 3, published.size
  ensure
    root = tui.instance_variable_get(:@root)
    FileUtils.remove_entry(root) if root.to_s.start_with?(Dir.tmpdir) && Dir.exist?(root)
  end

  def test_tui_done_completes_only_on_epic_written
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999)
    captured = []
    tui.define_singleton_method(:publish_envelope) do |f|
      captured << f
      f['request_id'] || "stub-#{captured.size}"
    end
    tui.handle_line('/goal want a thing')
    tui.handle_line('/done')
    req = captured.last['request_id']
    assert_equal :goal, tui.instance_variable_get(:@mode)

    # A planner error on the /done request keeps the session open.
    tui.handle_event("runes/prompts/#{req}/progress",
                     JSON.generate('event' => 'planner_error', 'error' => 'boom'))
    assert_equal :goal, tui.instance_variable_get(:@mode)
    assert_nil tui.instance_variable_get(:@pending_done_req)

    # Retry /done.
    tui.handle_line('/done')
    req2 = captured.last['request_id']
    refute_equal req, req2

    # T1: ANOTHER request's epic_written must not complete our /done.
    tui.handle_event('runes/prompts/other-req/progress',
                     JSON.generate('event' => 'epic_written', 'path' => '/x/other.md'))
    assert_equal :goal, tui.instance_variable_get(:@mode), 'foreign epic_written must not complete /done'
    assert_equal req2, tui.instance_variable_get(:@pending_done_req)

    # The matching epic lands -> build mode.
    tui.handle_event("runes/prompts/#{req2}/progress",
                     JSON.generate('event' => 'epic_written', 'path' => '/x/epic.md'))
    assert_equal :build, tui.instance_variable_get(:@mode)
    assert_nil tui.instance_variable_get(:@session_id)
    assert_equal '/x/epic.md', tui.instance_variable_get(:@last_epic)
  end

  def test_tui_publish_failure_rolls_back_goal_mode
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999, root: Dir.mktmpdir('tui-empty'))
    tui.define_singleton_method(:publish_envelope) { |_f| nil } # broker down
    tui.handle_line('/goal want a thing')
    assert_equal :build, tui.instance_variable_get(:@mode), 'failed /goal must roll back to build'
    assert_nil tui.instance_variable_get(:@session_id)

    tui.handle_line('/goal second try')
    tui.handle_line('/done')
    # The second /goal also fails and rolls back; /done then finds no
    # open session and must not wait on an epic.
    assert_equal :build, tui.instance_variable_get(:@mode)
    assert_nil tui.instance_variable_get(:@pending_done_req), 'failed /done must not wait on an epic'
  ensure
    root = tui.instance_variable_get(:@root)
    # SAFETY: only ever remove a tmpdir root — removing a default
    # (project) root here deleted the whole repository once.
    FileUtils.remove_entry(root) if root.to_s.start_with?(Dir.tmpdir) && Dir.exist?(root)
  end

  def test_tui_goal_restart_notice_and_build_abandon
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999)
    tui.define_singleton_method(:publish_envelope) { |_f| 'r' }
    tui.handle_line('/goal first idea')
    first_sid = tui.instance_variable_get(:@session_id)
    tui.handle_line('/goal second idea')
    assert tui.instance_variable_get(:@traffic).any? { |l| l.include?('abandoning previous goal session') }
    refute_equal first_sid, tui.instance_variable_get(:@session_id)

    tui.handle_line('/build')
    assert tui.instance_variable_get(:@traffic).any? { |l| l.include?('abandoning goal session') }
    assert_equal :build, tui.instance_variable_get(:@mode)
  end

  # S-T1: control characters in broker payloads never reach the TUI.
  def test_tui_scrubs_control_characters_from_events
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999)
    evil = "agent\e]52;c#payload\a-bot"
    tui.handle_event("runes/agents/#{evil}/status", "online\e[2Jspoof")
    traffic = tui.instance_variable_get(:@traffic).join("\n")
    agents = tui.instance_variable_get(:@agents).keys.join('|')
    refute traffic.match?(/[\x00-\x08\x0b-\x1f\x7f]/), 'control chars leaked into traffic'
    refute agents.match?(/[\x00-\x08\x0b-\x1f\x7f]/), 'control chars leaked into agent ids'
    assert tui.instance_variable_get(:@agents).key?('agent]52;c#payload-bot')
  end

  # S-T2: hostile publishers cannot grow the registry without bound.
  def test_tui_caps_agent_registry
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999)
    200.times do |i|
      tui.handle_event("runes/agents/ghost-#{i}/status", 'online')
    end
    assert_operator tui.instance_variable_get(:@agents).size, :<=, RunesTUI::LIMITS[:agents]
  end

  # --- helpers -----------------------------------------------------------

  def find_free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_port(port, timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        begin
          TCPSocket.new('127.0.0.1', port).close
          return
        rescue Errno::ECONNREFUSED
          sleep 0.05
        end
      end
    end
  end
end

load File.expand_path('../bin/runes', __dir__) unless defined?(RunesTUI)
