require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Regression tests for the security/correctness fix round:
#   * Guard instance isolation (no shared policy hash)
#   * Guard baseline builtin permissions + planner-path enforcement
#   * run_command injection, allowlist, timeout, output cap
#   * safe_path symlink escape
#   * per-request response correlation + prompt envelope
#   * plan step cap
#   * broker: callback re-publish (no deadlock), oversized packet drop
#   * delegation reply topic
#   * durable JSONL journal
class TestSecurityFixes < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-sec')
    ENV['RUNES_WORKSPACE'] = @tmp
    @settings = Runes::Core::Settings.new
    @dispatcher = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 18_883 },
      nil, nil,
      settings: @settings,
      agent_id: 'sec-test',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tmp_tools = Dir.mktmpdir('runes-sec-tools')),
      transport: RecordingTransport.new
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
    FileUtils.remove_entry(@tmp_tools) if @tmp_tools && Dir.exist?(@tmp_tools)
    ENV.delete('RUNES_WORKSPACE')
    %w[RUNES_CMD_ALLOWLIST RUNES_CMD_TIMEOUT_S RUNES_CMD_OUTPUT_CAP RUNES_MAX_STEPS].each { |k| ENV.delete(k) }
  end

  # --- Guard ---------------------------------------------------------

  def test_guard_instances_do_not_share_policy_state
    a = Runes::Capabilities::Guard.new
    b = Runes::Capabilities::Guard.new
    a.merge_fragment!({ 'tools' => { 'sneaky' => { 'mqtt_publish' => ['x'] } } })
    refute b.policy['tools'].key?('sneaky'), 'fragment leaked across Guard instances'
  end

  def test_guard_baseline_allows_builtins_by_default
    g = Runes::Capabilities::Guard.new
    assert g.allowed?('write_file', :fs_write, 'notes.txt')
    assert g.allowed?('read_file', :fs_read, 'notes.txt')
    assert g.allowed?('run_command', :exec, 'ls -la')
  end

  def test_guard_policy_file_can_revoke_baseline
    policy_path = File.join(@tmp, 'policy.json')
    File.write(policy_path, JSON.generate('default_allow' => false,
                                          'tools' => { 'run_command' => { 'exec' => [] } }))
    g = Runes::Capabilities::Guard.new(policy_path)
    refute g.allowed?('run_command', :exec, 'ls -la')
    assert g.allowed?('write_file', :fs_write, 'x.txt')
  end

  # --- S5-3: a policy that cannot be read is not a policy -----------------

  def test_guard_missing_policy_keeps_the_documented_baseline
    g = Runes::Capabilities::Guard.new(File.join(@tmp, 'no-such-policy.json'))
    refute g.policy_unreadable, 'a missing file means "no policy configured"'
    assert g.allowed?('write_file', :fs_write, 'x.txt')
    assert g.allowed?('run_command', :exec, 'ls')
  end

  def test_guard_corrupt_policy_fails_closed
    path = File.join(@tmp, 'corrupt-policy.json')
    File.write(path, '{"tools": {"write_file": ')
    g = Runes::Capabilities::Guard.new(path)

    assert g.policy_unreadable, 'a parse failure must be reported'
    refute g.allowed?('write_file', :fs_write, 'anything.txt'),
           'a malformed narrowing policy must not leave write_file allow-all'
    refute g.allowed?('read_file', :fs_read, 'anything.txt')
    refute g.allowed?('run_command', :exec, 'ls')
    assert_empty g.policy['tools'], 'no builtin baseline may survive a corrupt policy'
  end

  def test_guard_valid_narrowing_policy_is_honoured
    path = File.join(@tmp, 'narrow-policy.json')
    File.write(path, JSON.generate('default_allow' => false,
                                   'tools' => { 'run_command' => { 'exec' => ['ls'] } }))
    g = Runes::Capabilities::Guard.new(path)

    refute g.policy_unreadable
    assert g.allowed?('run_command', :exec, 'ls')
    refute g.allowed?('run_command', :exec, 'rm -rf /')
    # Tools the policy does not mention keep the documented builtin baseline.
    assert g.allowed?('write_file', :fs_write, 'x.txt')
  end

  # --- planner-path Guard enforcement --------------------------------

  def test_planner_path_denied_when_guard_revokes_exec
    policy_path = File.join(@tmp, 'policy.json')
    File.write(policy_path, JSON.generate('default_allow' => false,
                                          'tools' => { 'run_command' => { 'exec' => [] } }))
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 18_883 }, nil, nil,
      settings: @settings, agent_id: 'sec-denied',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tmp_tools),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@guard, Runes::Capabilities::Guard.new(policy_path))
    outcome = d.execute_step({ tool: 'run_command', args: { 'cmd' => 'ls' } }, 1)
    assert_includes outcome, 'capability denied'
  end

  # --- run_command hardening -----------------------------------------

  def test_run_command_blocks_newline_injection
    out = @dispatcher.send(:run_in_workspace, "echo ok\nrm -rf /tmp/x")
    assert_includes out, 'metacharacters'
  end

  def test_run_command_blocks_command_substitution
    out = @dispatcher.send(:run_in_workspace, 'echo $(whoami)')
    assert_includes out, 'metacharacters'
  end

  def test_run_command_blocks_parameter_expansion
    out = @dispatcher.send(:run_in_workspace, 'echo ${HOME}')
    assert_includes out, 'metacharacters'
  end

  def test_run_command_allows_fd_to_fd_redirects_only
    out = @dispatcher.send(:run_in_workspace, 'echo hi 2>&1')
    assert_includes out, 'exit=0'
    assert_includes out, 'hi'
  end

  def test_run_command_still_blocks_file_redirects_next_to_fd_redirect
    out = @dispatcher.send(:run_in_workspace, 'echo x > /tmp/pwned 2>&1')
    assert_includes out, 'metacharacters'
    refute File.exist?('/tmp/pwned')
  end

  def test_run_command_allowlist_blocks_unchained_exec
    ENV['RUNES_CMD_ALLOWLIST'] = 'ls'
    assert_includes @dispatcher.send(:run_in_workspace, 'ruby -e "puts 1"'), 'not on RUNES_CMD_ALLOWLIST'
    assert_includes @dispatcher.send(:run_in_workspace, 'ls'), 'exit=0'
  end

  # S5-2 regression: the verified escape was
  #   run_in_workspace(%q{ruby -e 'File.write("<outside>","x")'})
  # which returned exit=0 and created the file. An interpreter is refused
  # by the DEFAULT allowlist now, so the write cannot happen.
  def test_run_command_interpreter_cannot_write_outside_the_workspace
    outside = File.join(Dir.mktmpdir('runes-sec-outside'), 'escaped.txt')
    payload = %(ruby -e 'File.write("#{outside}","pwned")')
    out = @dispatcher.send(:run_in_workspace, payload)
    refute_includes out, 'exit=0'
    assert_match(/not on RUNES_CMD_ALLOWLIST|path escapes the workspace/, out)
    refute File.exist?(outside), 'an interpreter payload must not escape the workspace'
  ensure
    FileUtils.remove_entry(File.dirname(outside)) if outside && Dir.exist?(File.dirname(outside))
  end

  def test_run_command_timeout_kills_hanging_process
    ENV['RUNES_CMD_TIMEOUT_S'] = '0.3'
    out = @dispatcher.send(:run_in_workspace, 'sleep 5')
    assert_includes out, 'timed out'
  end

  def test_run_command_output_cap
    ENV['RUNES_CMD_OUTPUT_CAP'] = '200'
    File.write(File.join(@tmp, 'big.txt'), 'x' * 100_000)
    out = @dispatcher.send(:run_in_workspace, 'cat big.txt')
    assert_includes out, 'truncated'
    assert out.bytesize < 500
  end

  # S5-2b: a script written by write_file must not be executable.
  def test_run_command_refuses_a_workspace_script
    @dispatcher.send(:execute_builtin, 'write_file',
                     { 'path' => 'evil.sh', 'content' => "echo pwned\n" })
    out = @dispatcher.send(:run_in_workspace, './evil.sh')
    refute_includes out, 'pwned'
    assert_match(/not on RUNES_CMD_ALLOWLIST|command paths are not allowed/, out)
  end

  # S5-2c: a path attached to an option (`-o/tmp/x`) must be scanned.
  def test_command_path_violation_flags_attached_option_paths
    d = @dispatcher
    assert_equal '/tmp/out', d.send(:command_path_violation?, 'curl -o/tmp/out http://x')
    assert_equal '/tmp/out', d.send(:command_path_violation?, 'tool --out=/tmp/out')
    assert_nil d.send(:command_path_violation?, 'ls -la')
    assert_nil d.send(:command_path_violation?, 'rm -rf nested/dir')
  end

  # S5-2d: text safe_path would happily call a relative filename is refused.
  def test_command_path_violation_refuses_unclassifiable_tokens
    d = @dispatcher
    assert_equal 'File.write("/x","y")',
                 d.send(:command_path_violation?, 'File.write("/x","y")')
    assert_nil d.send(:command_path_violation?, 'cat src/main.rb')
  end

  # --- safe_path symlink escape ---------------------------------------

  def test_safe_path_blocks_symlink_escape
    File.symlink('/etc', File.join(@tmp, 'escape'))
    assert_nil @dispatcher.send(:safe_path, 'escape/passwd')
  end

  def test_safe_path_accepts_not_yet_existing_nested_paths
    path = @dispatcher.send(:safe_path, 'a/b/c.txt')
    refute_nil path
    assert path.start_with?(File.expand_path(@tmp))
  end

  # --- per-request response correlation --------------------------------

  class StubLLM
    def call(_prompt, **)
      { ok: true, mode: :tool_calls, tool_calls: [{ tool: 'echo', args: { 'message' => 'hi' } }], raw: {} }
    end
  end

  class PublishingClient
    def initialize(broker)
      @broker = broker
    end

    def publish(topic, payload, retain: false)
      @broker.publish(topic, payload, retain: retain)
    end
  end

  def test_prompt_envelope_honors_request_id_and_reply_topic
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: @settings, agent_id: 'sec-env',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tmp_tools),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@llm, StubLLM.new)
    # Attach a client that only records publications.
    recorded = []
    d.define_singleton_method(:publish_result) do |client, reply_topic, summary|
      recorded << [reply_topic, summary]
    end
    d.handle_prompt(PublishingClient.new(broker),
                    JSON.generate('request_id' => 'req77', 'prompt' => 'hello'))
    reply, = recorded.last
    assert_equal 'runes/prompts/req77/response', reply
  end

  def test_plan_step_cap_truncates
    ENV['RUNES_MAX_STEPS'] = '2'
    llm = Object.new
    llm.define_singleton_method(:call) do |*|
      { ok: true, mode: :tool_calls,
        tool_calls: Array.new(5) { { tool: 'echo', args: { 'message' => 'x' } } }, raw: {} }
    end
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: @settings, agent_id: 'sec-cap',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tmp_tools),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@llm, llm)
    executed = []
    d.define_singleton_method(:execute_step) { |step, _| executed << step; 'ok' }
    d.handle_payload('go')
    assert_equal 2, executed.size
  end

  # --- delegation reply topic ------------------------------------------

  def test_delegated_task_publishes_correlated_reply
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: @settings, agent_id: 'sec-del',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tmp_tools),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@llm, StubLLM.new)
    replies = []
    d.define_singleton_method(:publish_result) do |_c, reply_topic, summary|
      replies << [reply_topic, summary]
    end
    d.handle_delegated_task(
      JSON.generate('prompt' => 'do it', 'from' => 'peer-a', 'request_id' => 'r9')
    )
    reply, = replies.last
    assert_equal 'runes/agents/peer-a/tasks/r9/response', reply
  end

  # --- broker ----------------------------------------------------------

  def test_in_process_subscriber_can_republish_without_deadlock
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    seen = Queue.new
    echoed = Queue.new
    broker.subscribe('in/#') do |topic, payload|
      seen << [topic, payload]
      # Re-entrant publish inside the callback used to raise ThreadError
      # (recursive mutex) because delivery ran under the broker lock.
      broker.publish('echoed', payload) unless topic == 'echoed'
    end
    broker.subscribe('echoed') { |t, p| echoed << [t, p] }
    broker.publish('in/one', 'x')
    assert_equal ['in/one', 'x'], seen.pop
    assert_equal ['echoed', 'x'], Timeout.timeout(2) { echoed.pop }
  end

  def test_broker_drops_oversized_packets
    port = find_free_port
    broker_thread = Thread.new { Runes::MQTT::Broker.new('127.0.0.1', port).run }
    wait_for_port(port)
    sock = TCPSocket.new('127.0.0.1', port)
    # CONNECT first so the broker enters its loop cleanly.
    # Remaining length = 10: proto_len(2) + "MQTT"(4) + level(1) + flags(1) + keepalive(2)
    connect = [0x10].pack('C') + [10].pack('C') + [0x00, 0x04].pack('n') + 'MQTT' + [0x04, 0x02].pack('CC') + [30].pack('n')
    sock.write(connect)
    sleep 0.1
    # Publish header declaring a ~256MB payload.
    sock.write([0x30].pack('C') + [0xFF, 0xFF, 0xFF, 0x7F].pack('C4'))
    sock.write('short')
    sleep 0.2
    # A reset or EOF both prove the broker dropped the client (it may
    # RST because we left unread data in flight).
    closed = begin
      sock.eof?
    rescue Errno::ECONNRESET, Errno::EPIPE
      true
    end
    assert closed, 'broker should have closed an oversized-packet client'
  ensure
    sock&.close
    broker_thread&.kill
  end

  # --- durable journal ---------------------------------------------------

  def test_prompt_log_appends_to_jsonl_journal
    root = Dir.mktmpdir('runes-sec-root')
    settings = Runes::Core::Settings.new(root: root)
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: settings, agent_id: 'sec-journal',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tmp_tools),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@llm, StubLLM.new)
    d.handle_payload('journal me')
    path = File.join(root, 'log', 'journal.jsonl')
    assert File.file?(path), 'journal file should exist'
    entry = JSON.parse(File.readlines(path).last)
    assert_equal 'complete', entry['status']
    assert_equal 'sec-journal', entry['agent']
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
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
