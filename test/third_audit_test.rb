require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Regression tests for the third audit round (docs/How this started/doc.md):
#   Dispatcher: D1-D11, S-D1, S-D2, S-D3, S-R1, S-W3
#   Broker:     M1-M11, S-M1, S-M2
#   Guard:      S-D4, S-W4, S-R2, W3
#   VM:         W1, W2, W4, W5, S-W1
#   Settings:   R1, R3, R4, S-R1
#   Registry:   R2, S-R3, S-R4
#   LLM:        L3, L4, L5, L7, S-L1, S-L2, S-L3
#   TUI/CLI:    T1-T5, T7, T8, S-T1, S-T2
#
# NOTE: every test that touches a filesystem root creates its own
# tmpdir; teardown only ever removes paths under Dir.tmpdir.
class TestThirdAudit < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-a3')
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)
    ENV['RUNES_WORKSPACE'] = File.join(@tmp, 'workspace')
    @tools = Dir.mktmpdir('runes-a3-tools')
    FileUtils.mkdir_p(File.join(@tools, 'echo'))
    File.write(File.join(@tools, 'echo', 'capabilities.json'),
               JSON.generate('mqtt_publish' => ['runes/tools/echo/response']))
    File.write(File.join(@tools, 'echo', 'run.rb'), "puts input['message']")
    @settings = Runes::Core::Settings.new(root: @tmp)
  end

  def teardown
    @broker_thread&.kill
    [@tmp, @tools].each do |d|
      FileUtils.remove_entry(d) if d.to_s.start_with?(Dir.tmpdir) && Dir.exist?(d)
    end
    ENV.delete('RUNES_WORKSPACE')
    %w[RUNES_EXEC_TTL_S RUNES_CMD_TIMEOUT_S RUNES_LLM_TIMEOUT_S RUNES_ALLOW_PROVIDER_FALLBACK
       RUNES_REDACT_PROMPTS RUNES_WASM_TIMEOUT_S].each { |k| ENV.delete(k) }
  end

  def make_dispatcher(agent_id)
    Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: Runes::Transport::MQTT311.new(host: '127.0.0.1', port: @port, client_id: "test-#{SecureRandom.hex(4)}").connect
    )
  end

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

  # --- D1: deterministic request-id fallback ---------------------------

  def test_sanitize_request_id_fallback_is_deterministic
    d = make_dispatcher('a3-d1')
    a = d.send(:sanitize_request_id, 'bad id with spaces anddots.too.long.x' * 3)
    b = make_dispatcher('a3-d1b').send(:sanitize_request_id, 'bad id with spaces anddots.too.long.x' * 3)
    assert_equal a, b, 'every agent must derive the same fallback id'
    assert_match(/\A[A-Za-z0-9_-]{1,32}\z/, a)
  end

  # --- D2/D3: claim lifecycle ---------------------------------------------

  # --- D4: atomic check-and-mark ------------------------------------------

  # --- D5: tool requests off the reactive loop ------------------------------

  # --- D6 + S4-1: tool RPC is reachable only with the shared secret --------

  def test_tool_rpc_requires_the_shared_secret
    ENV['RUNES_TOOL_RPC'] = '1'
    ENV['RUNES_RPC_SECRET'] = 'test-secret'
    d = make_dispatcher('a3-d6')
    replied = Queue.new
    client = Object.new
    client.define_singleton_method(:publish) { |topic, payload| replied << [topic, payload] }

    # Unauthenticated (S4-1/E4-6): refused, and nothing is executed.
    d.handle_tool_request(client, 'write_file', JSON.generate('path' => 'rpc.txt', 'content' => 'hi'))
    topic, payload = replied.pop
    assert_equal 'runes/tools/write_file/error', topic
    assert_includes payload, 'unauthorized'
    refute File.file?(File.join(@tmp, 'workspace', 'rpc.txt'))

    # A wrong secret is refused too.
    d.handle_tool_request(client, 'write_file',
                          JSON.generate('path' => 'rpc.txt', 'content' => 'hi', 'token' => 'nope'))
    topic, payload = replied.pop
    assert_equal 'runes/tools/write_file/error', topic
    refute File.file?(File.join(@tmp, 'workspace', 'rpc.txt'))

    # Authenticated: executes without needing an mqtt_publish grant (D6).
    signed = Runes::Security::RPCAuth.sign(
      'test-secret', 'write_file', { 'path' => 'rpc.txt', 'content' => 'hi' }
    ).merge('token' => 'test-secret')
    d.handle_tool_request(client, 'write_file', JSON.generate(signed))
    topic, payload = replied.pop
    assert_equal 'runes/tools/write_file/response', topic
    assert_includes payload, 'Wrote'
    assert File.file?(File.join(@tmp, 'workspace', 'rpc.txt'))
  ensure
    ENV.delete('RUNES_TOOL_RPC')
    ENV.delete('RUNES_RPC_SECRET')
  end

  # S5-4: a valid request replays only once, and a stale timestamp is
  # refused even with a correct MAC.
  def test_tool_rpc_requests_are_fresh_and_not_replayable
    ENV['RUNES_TOOL_RPC'] = '1'
    ENV['RUNES_RPC_SECRET'] = 'test-secret'
    d = make_dispatcher('a3-s54')
    replied = Queue.new
    client = Object.new
    client.define_singleton_method(:publish) { |topic, payload| replied << [topic, payload] }

    signed = Runes::Security::RPCAuth.sign(
      'test-secret', 'read_file', { 'path' => 'rpc.txt' }
    ).merge('token' => 'test-secret')
    payload = JSON.generate(signed)

    d.handle_tool_request(client, 'read_file', payload)
    assert_equal 'runes/tools/read_file/response', replied.pop.first

    # The exact same request is a replay: refused.
    d.handle_tool_request(client, 'read_file', payload)
    topic, body = replied.pop
    assert_equal 'runes/tools/read_file/error', topic
    assert_includes body, 'unauthorized'

    # A stale timestamp fails the freshness window even with a valid MAC.
    stale = Runes::Security::RPCAuth.sign(
      'test-secret', 'read_file', { 'path' => 'rpc.txt' },
      ts: Time.now.to_i - 10_000
    ).merge('token' => 'test-secret')
    d.handle_tool_request(client, 'read_file', JSON.generate(stale))
    topic, = replied.pop
    assert_equal 'runes/tools/read_file/error', topic

    # A tampered body invalidates the MAC.
    tampered = signed.merge('path' => '/etc/passwd')
    d.handle_tool_request(client, 'read_file', JSON.generate(tampered))
    topic, = replied.pop
    assert_equal 'runes/tools/read_file/error', topic
  ensure
    ENV.delete('RUNES_TOOL_RPC')
    ENV.delete('RUNES_RPC_SECRET')
  end

  # --- D7: atomic mission writes -------------------------------------------

  def test_save_mission_never_leaves_tmp_files
    d = make_dispatcher('a3-d7')
    dir = File.join(@tmp, 'docs', 'missions')
    FileUtils.mkdir_p(dir)
    json_path = File.join(dir, 'm.json')
    md_path = File.join(dir, 'm.md')
    sidecar = { 'mission_title' => 't', 'todos' => [] }
    assert d.save_mission(sidecar, json_path, md_path)
    assert_empty Dir.glob(File.join(dir, '*.tmp-*'))
    assert_equal sidecar, JSON.parse(File.read(json_path))
  end

  # --- D9: latest mission restored at boot ----------------------------------

  def test_latest_mission_loaded_at_boot
    dir = File.join(@tmp, 'docs', 'missions')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, '20260907-120000-m.json'), '{}')
    d = make_dispatcher('a3-d9')
    assert_equal File.join(dir, '20260907-120000-m.json'), d.instance_variable_get(:@latest_mission)
    assert_equal File.join(dir, '20260907-120000-m.json'), d.resolve_mission_path('latest')
  end

  # --- D10: delegated task topic validation ---------------------------------

  def test_delegated_task_rejects_unsafe_from_field
    d = make_dispatcher('a3-d10')
    replied = []
    d.define_singleton_method(:publish_result) { |_c, t, _s| replied << t }
    d.instance_variable_set(:@llm, StubLLM.new)
    client = Object.new
    client.define_singleton_method(:publish) { |*_a| }
    d.handle_delegated_task(
                            JSON.generate('prompt' => 'x', 'from' => 'peer/../evil', 'request_id' => 'r1'))
    assert replied.empty? || replied.first.nil?, 'reply topic must be suppressed for unsafe from'
    # Safe ids still work.
    d.handle_delegated_task(
                            JSON.generate('prompt' => 'x', 'from' => 'peer-ok', 'request_id' => 'r2'))
    assert_equal 'runes/agents/peer-ok/tasks/r2/response', replied.last
  end

  # --- D11: one canonical envelope detection --------------------------------

  def test_whitespace_prefixed_envelope_is_detected_consistently
    d = make_dispatcher('a3-d11')
    payload = '  {"request_id": "ws1", "prompt": "hello"}'
    env = d.parse_envelope(payload)
    rid, prompt, from_env = d.parse_prompt_payload(payload)
    assert from_env
    assert_equal env[:request_id], rid, 'envelope detection must agree across parsers'
    assert_equal 'hello', prompt
  end

  # --- S-D1: sibling-directory containment -----------------------------------

  def test_mission_and_epic_paths_reject_sibling_prefix_dirs
    d = make_dispatcher('a3-sd1')
    evil = File.join(@tmp, 'docs', 'missions-evil')
    FileUtils.mkdir_p(evil)
    evil_file = File.join(evil, 'm.md')
    File.write(evil_file, 'x')
    assert_nil d.resolve_mission_path(evil_file)
    refute d.send(:valid_mission_path?, evil_file)
  end

  # --- S-W3: manifest tools are guard-enforced --------------------------------

  def test_manifest_tool_execution_requires_execute_grant
    d = make_dispatcher('a3-sw3')
    policy_path = File.join(@tmp, 'policy.json')
    File.write(policy_path, JSON.generate('default_allow' => false, 'tools' => {}))
    d.instance_variable_set(:@guard, Runes::Capabilities::Guard.new(
      policy_path,
      additional_fragments: [{ 'tools' => { 'echo' => { 'mqtt_publish' => ['runes/tools/echo/response'] } } }]
    ))
    outcome = d.execute_step({ tool: 'echo', args: { 'message' => 'x' } }, 1)
    assert_includes outcome, 'capability denied', 'manifest tools must be guard-enforced'
  end

  # --- S-D3: prompt redaction hook ---------------------------------------------

  def test_prompt_log_redaction_hook
    d = make_dispatcher('a3-sd3')
    assert_includes d.send(:loggable_prompt, 'secret stuff'), 'secret stuff'
    ENV['RUNES_REDACT_PROMPTS'] = '1'
    redacted = d.send(:loggable_prompt, 'secret stuff')
    refute_includes redacted, 'secret stuff'
    assert_includes redacted, '[redacted'
  end

  # --- Guard S-D4 / S-W4 ------------------------------------------------------

  def test_guard_known_tool_missing_action_fails_closed
    policy_path = File.join(@tmp, 'policy-sd4.json')
    File.write(policy_path, JSON.generate('default_allow' => true,
                                          'tools' => { 'run_command' => { 'exec' => ['#'] } }))
    g = Runes::Capabilities::Guard.new(policy_path)
    refute g.allowed?('run_command', :fs_write, 'x'), 'known tool + missing action must not fall through to default_allow'
  end

  def test_guard_hash_does_not_match_empty_topic
    g = Runes::Capabilities::Guard.new
    refute g.allowed?('write_file', :fs_write, ''), "the empty topic must not match '#' (S-W4)"
  end

  # --- W3: malformed fragments fail closed, not crash ---------------------------

  def test_guard_malformed_fragments_do_not_crash_constructor
    g = Runes::Capabilities::Guard.new(nil, additional_fragments: [
      { 'tools' => { 'x' => ['#'] } } # rules is an Array — malformed
    ])
    refute g.allowed?('x', :mqtt_publish, 'any'), 'malformed rules must fail closed'
  end

  # --- S-W1: fail-closed workspace default --------------------------------------

  def test_vm_manager_default_has_no_workspace_preopen
    mgr = Runes::WASM::VMManager.new('missing.wasm', backend: :mock)
    vm = mgr.acquire
    vm.run('puts 1') # smoke
    assert_nil mgr.instance_variable_get(:@workspace), 'library default must not preopen anything'
    mgr.release(vm)
  end

  # --- W2: explicit :real with missing binary fails loud --------------------------

  def test_real_backend_with_missing_binary_raises
    assert_raises(ArgumentError) do
      Runes::WASM::VMManager.new('definitely-missing.wasm', backend: :real)
    end
  end

  # --- R1: SQLite busy timeout + WAL ----------------------------------------------

  def test_settings_configure_busy_timeout_and_wal
    s = Runes::Core::Settings.new(root: @tmp)
    db = s.instance_variable_get(:@db)
    mode = db.execute('PRAGMA journal_mode')
    assert_equal 'wal', mode.flatten.first.to_s.downcase
    timeout = db.execute('PRAGMA busy_timeout')
    assert_equal 5000, timeout.flatten.first.to_i
  end

  # --- R2/S-R3/S-R4: registry scan hardening + rescan ------------------------------

  def test_registry_scans_without_precheck_crash_and_supports_rescan
    reg = Runes::Core::ToolRegistry.new(tools_dir: @tools)
    assert_instance_of Runes::Core::ToolRegistry, reg
    assert_same reg, reg.rescan
  end

  def test_registry_manifest_digests_exposed
    reg = Runes::Core::ToolRegistry.new(tools_dir: @tools)
    assert reg.manifest_digests.key?('echo')
    assert_match(/\A[0-9a-f]{64}\z/, reg.manifest_digests['echo'])
  end

  # --- T7: runes-replay rejects negative -n -----------------------------------------

  def test_replay_negative_last_is_rejected
    out = IO.popen(['ruby', File.expand_path('../bin/runes-replay', __dir__), '-n', '-5'],
                   err: [:child, :out]) { |io| io.read }
    refute_equal 0, $?
    assert_includes out, 'must be >= 0'
  end

  # --- T8 / X5-2: agent-id charset (real validator + fail-fast construction) ----

  def test_agent_id_charset_matches_topic_safety
    # D5-3: this used to assert literals against a LOCAL regex. Use the
    # production constant, then prove the dispatcher enforces it.
    safe = Runes::Core::Dispatcher::AGENT_ID_RE
    assert 'agent-1'.match?(safe)
    refute 'peer/../evil'.match?(safe)
    refute 'wildcard+id'.match?(safe)
    refute 'hash#id'.match?(safe)
  end

  def test_dispatcher_rejects_hostile_agent_ids_at_construction
    hostile = ['with space', 'colon:id', 'slash/id', 'plus+id', 'hash#id', 'a' * 65]
    hostile.each do |bad|
      error = assert_raises(ArgumentError, "#{bad.inspect} must be rejected") do
        Runes::Core::Dispatcher.new(
          { host: '127.0.0.1', port: 0 }, nil, nil,
          settings: @settings, agent_id: bad,
          tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
          transport: RecordingTransport.new
        )
      end
      assert_includes error.message, 'invalid agent id'
    end
  end

  # --- S-M2 / M6 / M8 / M9: broker protocol hardening ------------------------------

  def test_broker_caps_constants
    assert_equal 256, Runes::MQTT::Broker::MAX_CONNECTIONS
    assert_equal 64, Runes::MQTT::Broker::MAX_SUBSCRIPTIONS_PER_CLIENT
  end

  def test_malformed_remaining_length_is_detected
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    # 4 length bytes all carrying the continuation bit
    packet = [0x30].pack('C') + [0xFF, 0xFF, 0xFF, 0xFF].pack('C4')
    io = StringIO.new(packet)
    assert_equal :malformed, broker.send(:read_packet, io, nil)
  end

  def test_keepalive_zero_is_honored
    broker = Runes::MQTT::Broker.new
    written = String.new
    client = Object.new
    client.define_singleton_method(:write) { |data| written << data }
    payload = [4].pack('n') + 'MQTT' + [4, 0, 0].pack('CCn')
    keepalive = broker.send(:handle_connect, client, payload)
    assert_equal 0, keepalive, 'keepalive 0 must be preserved (no timeout)'
  end

  def test_remaining_length_varint_encoding_beyond_one_byte
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    io = StringIO.new
    broker.send(:encode_remaining_length, 130, io)
    assert_equal [130, 1].pack('C2').bytes, io.string.bytes
  end

  # --- L4: total retry deadline -------------------------------------------------------

  def test_llm_deadline_caps_total_retry_window
    ENV['RUNES_LLM_TIMEOUT_S'] = '1'
    llm = Runes::Core::LLMClient.new(@settings)
    calls = { n: 0 }
    llm.define_singleton_method(:attempt_request) do |_uri, _route, _body, timeout|
      calls[:n] += 1
      calls[:last_timeout] = timeout
      sleep 0.05
      nil # always "timed out"
    end
    uri = URI.parse('https://api.example/v1/chat/completions')
    route = Runes::Core::LLMClient::Route.new(
      provider: 'cerebras', base_url: 'https://api.example/v1', model: 'm',
      variation: 'high', sampling_params: {}, api_key: 'k'
    )
    t0 = Time.now
    resp = llm.send(:request_with_retry, route, uri, '{}')
    elapsed = Time.now - t0
    assert_nil resp
    assert_operator elapsed, :<, 3.0, "retry loop must respect the total deadline (took #{elapsed.round(2)}s)"
    assert_operator calls[:n], :<, 4, 'deadline must cut attempts short'
  end

  # --- S-L2: fallback opt-out -----------------------------------------------------------

  def test_provider_fallback_env_opt_out
    ENV['RUNES_ALLOW_PROVIDER_FALLBACK'] = '0'
    d = make_dispatcher('a3-sl2')
    res = d.instance_variable_get(:@llm).call('hello')
    refute res[:ok]
    assert_includes res[:error], 'fallback is disabled'
  end

  # --- W5/W6: mock marking + truncation flag --------------------------------------------

  def test_mock_run_result_is_marked
    mgr = Runes::WASM::VMManager.new('missing.wasm', backend: :mock)
    vm = mgr.acquire
    res = vm.run('puts 1')
    assert res[:mock]
    assert_equal false, res[:truncated]
    mgr.release(vm)
  end

  # --- S-T1: TUI sanitize helper ------------------------------------------------------------

  def test_tui_sanitize_strips_escapes
    load File.expand_path('../bin/runes', __dir__)
    dirty = "\e]52;c#clip\a online\e[2J"
    clean = RunesTUI.sanitize(dirty)
    refute clean.match?(/[\x00-\x08\x0b-\x1f\x7f]/)
    assert_equal ']52;c#clip online[2J', clean
  end

  class StubLLM
    def call(_prompt, **)
      { ok: true, mode: :tool_calls, tool_calls: [], raw: {} }
    end
  end
end
