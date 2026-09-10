require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Tests for Phase-5 enhancements: function-calling mode, manifest/WASM
# tool execution, cross-dispatcher delegation, durable prompt log.
class TestDispatcherEnhancements < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-enh')
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)

    ENV['RUNES_WORKSPACE'] = @tmp
    @tools_tmp = Dir.mktmpdir('runes-enh-tools')
    FileUtils.mkdir_p(File.join(@tools_tmp, 'echo'))
    File.write(File.join(@tools_tmp, 'echo', 'card.json'),
               JSON.generate('name' => 'echo', 'description' => 'echoes its args',
                             'parameters' => { 'type' => 'object', 'properties' => { 'message' => { 'type' => 'string' } } }))
    File.write(File.join(@tools_tmp, 'echo', 'capabilities.json'),
               JSON.generate('mqtt_publish' => ['runes/tools/echo/response']))
    File.write(File.join(@tools_tmp, 'echo', 'run.rb'), "puts input['message']")

    @settings = Runes::Core::Settings.new
    @registry = Runes::Core::ToolRegistry.new(tools_dir: @tools_tmp)
    self.class.current = self
  end

  def teardown
    @disp_thread&.kill
    @broker_thread&.kill
    [@tmp, @tools_tmp].each do |d|
      FileUtils.remove_entry(d) if d && Dir.exist?(d)
    end
    ENV.delete('RUNES_WORKSPACE')
    ENV.delete('RUNES_USE_TOOLS')
  end

  def make_dispatcher(agent_id:, llm:)
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings,
      agent_id: agent_id,
      tool_registry: @registry,
      transport: Runes::Transport::MQTT311.new(host: '127.0.0.1', port: @port, client_id: "test-#{SecureRandom.hex(4)}").connect
    )
    d.instance_variable_set(:@llm, llm)
    d
  end

  # --- function-calling mode -----------------------------------------

  def test_use_tool_calling_is_on_by_default
    d = make_dispatcher(agent_id: 'enh-a', llm: nil)
    assert d.use_tool_calling?, 'native tool_calls are the default planner path'
  end

  def test_use_tool_calling_respects_env_flag
    ENV['RUNES_USE_TOOLS'] = '1'
    d = make_dispatcher(agent_id: 'enh-b', llm: nil)
    assert d.use_tool_calling?
  end

  def test_use_tool_calling_can_be_opted_out_via_env
    ENV['RUNES_USE_TOOLS'] = '0'
    d = make_dispatcher(agent_id: 'enh-b2', llm: nil)
    refute d.use_tool_calling?, 'RUNES_USE_TOOLS=0 must restore free-form JSON plans'
  end

  def test_tool_schemas_include_builtins_and_registry_tools
    d = make_dispatcher(agent_id: 'enh-c', llm: nil)
    schemas = d.tool_schemas
    names = schemas.map { |s| s.dig(:function, :name) }
    assert_includes names, 'write_file'
    assert_includes names, 'echo'
  end

  def test_handle_prompt_uses_tool_calls_mode_by_default
    ENV.delete('RUNES_USE_TOOLS')
    calls = []
    llm = Object.new
    llm.define_singleton_method(:call) do |prompt, **kw|
      calls << kw
      { ok: true, mode: :tool_calls, tool_calls: [{ tool: 'echo', args: { 'message' => 'hi' } }], raw: {} }
    end
    d = make_dispatcher(agent_id: 'enh-d', llm: llm)

    topics = subscribe_to('runes/prompts/response', 'enh-d')
    d.handle_payload('say hi')
    payload = pop_topic(topics)

    assert_equal({ tools: d.tool_schemas }, calls.first)
    assert_includes payload, 'echo'
    assert_includes payload, 'WASM(echo)'
  end

  # --- manifest tool execution ---------------------------------------

  def test_manifest_tool_executes_via_wasm_backend
    d = make_dispatcher(agent_id: 'enh-e', llm: nil)
    outcome = d.execute_step({ tool: 'echo', args: { 'message' => 'hello' } }, 1)
    # Mock backend echoes the payload size; the point is that the
    # manifest tool ran inside the VM (not "unknown tool").
    assert_includes outcome, 'WASM(echo): [mock]'
    refute_includes outcome, 'unknown tool'
    refute_includes outcome, 'no implementation'
    # args scratch file must be cleaned up
    refute Dir.glob(File.join(@tmp, '.runes-args-*.json')).any?
  end

  def test_unknown_tool_still_errors
    d = make_dispatcher(agent_id: 'enh-f', llm: nil)
    outcome = d.execute_step({ tool: 'nope', args: {} }, 1)
    assert_includes outcome, 'unknown tool nope'
  end

  # --- delegation ----------------------------------------------------

  def test_delegate_to_publishes_envelope_on_peer_tasks_topic
    d = make_dispatcher(agent_id: 'enh-g', llm: nil)
    topics = subscribe_to('runes/agents/peer-9/tasks', 'enh-g')
    d.delegate_to(fake_client, 'peer-9', 'please do X')
    env = JSON.parse(pop_topic(topics))
    assert_equal 'please do X', env['prompt']
    assert_equal 'enh-g', env['from']
  end

  def test_delegated_task_is_handled_as_prompt
    llm = Object.new
    llm.define_singleton_method(:call) do |*|
      { ok: true, mode: :tool_calls, tool_calls: [{ tool: 'echo', args: { 'message' => 'delegated' } }], raw: {} }
    end
    d = make_dispatcher(agent_id: 'enh-h', llm: llm)
    topics = subscribe_to('runes/prompts/response', 'enh-h')
    d.handle_delegated_task(JSON.generate('prompt' => 'run echo', 'from' => 'someone'))
    assert_includes pop_topic(topics), 'echo'
  end

  # --- durable prompt log --------------------------------------------

  def test_prompt_log_records_completion_and_latest_snapshot
    d = make_dispatcher(agent_id: 'enh-i', llm: StubLLM.new)
    topics = subscribe_to('runes/_log/prompts', 'enh-i')
    latest = subscribe_to('runes/_log/prompts/latest', 'enh-i')

    d.handle_payload('log me')

    entry = JSON.parse(pop_topic(topics))
    assert_equal 'complete', entry['status']
    assert_equal 'log me', entry['prompt']
    assert_equal 'enh-i', entry['agent']
    snapshot = JSON.parse(pop_topic(latest))
    assert_equal entry['request_id'], snapshot['request_id']
  end

  def test_prompt_log_records_planner_error
    d = make_dispatcher(agent_id: 'enh-j', llm: ErrorLLM.new)
    topics = subscribe_to('runes/_log/prompts', 'enh-j')
    d.handle_payload('boom')
    entry = JSON.parse(pop_topic(topics))
    assert_equal 'planner_error', entry['status']
  end

  # --- stubs ---------------------------------------------------------

  class StubLLM
    def call(_prompt, **)
      { ok: true, mode: :tool_calls, tool_calls: [{ tool: 'echo', args: { 'message' => 'x' } }], raw: {} }
    end
  end

  class ErrorLLM
    def call(_prompt, **)
      { ok: false, error: 'no key' }
    end
  end

  # Publishes via a real TCP MQTT client — the broker's in-process API
  # only reaches in-process subscribers, and our test subscribers are
  # TCP clients.
  class FakeClient
    def self.publish(topic, payload, retain: false, **)
      c = MQTT::Client.connect('127.0.0.1', TestDispatcherEnhancements.current.instance_variable_get(:@port))
      c.publish(topic, payload, retain: retain)
      c.disconnect
    ensure
      begin
        c&.disconnect
      rescue StandardError
        nil
      end
    end
  end

  class << self
    attr_accessor :current
  end

  def fake_client
    FakeClient
  end

  def subscribe_to(filter, tag)
    q = Queue.new
    client = MQTT::Client.connect('127.0.0.1', @port, client_id: "sub-#{tag}-#{rand(1_000)}")
    client.subscribe(filter)
    Thread.new do
      client.get { |_t, m| q << m }
    end
    q
  end

  def pop_topic(queue, timeout: 5)
    Timeout.timeout(timeout) { queue.pop }
  end

  def wait_for_port(port, timeout: 5)
    require 'socket'
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

  def find_free_port
    require 'socket'
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end
end
