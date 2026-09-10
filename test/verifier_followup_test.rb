require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Regression tests for the verifier follow-up round:
#   D5 — tool RPCs never run inline on the reactive loop; at saturation
#        they get a visible busy error instead of stalling routing
#   L2 — unparseable tool-call arguments fail the planner response
#   T5 — registry panel rows are display-budgeted (columns, not chars)
#   R5 — dead DB_PATH constant removed
#   broker — keepalive-0 clients keep an absolute mid-packet deadline
class TestVerifierFollowup < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-vf')
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)
    ENV['RUNES_WORKSPACE'] = File.join(@tmp, 'workspace')
    @tools = Dir.mktmpdir('runes-vf-tools')
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
    ENV.delete('RUNES_MAX_CONCURRENT')
  end

  def make_dispatcher(agent_id, llm: nil)
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@llm, llm) if llm
    d
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

  # --- D5: saturation must not stall the loop ----------------------------

  def test_tool_request_at_saturation_gets_busy_error_and_loop_stays_fast
    d = make_dispatcher('vf-d5')
    transport = d.instance_variable_get(:@transport)

    # Saturate the dedicated tool pool.
    d.instance_variable_get(:@tool_in_flight_mutex).synchronize do
      d.instance_variable_set(:@tool_in_flight, d.max_tool_concurrent)
    end

    t0 = Time.now
    d.dispatch_tool_request('echo', '{}')
    elapsed = Time.now - t0

    assert_operator elapsed, :<, 0.5,
                    "saturated tool request blocked for #{elapsed.round(2)}s"
    refusal = transport.published.find { |p| p[:topic] == 'runes/tools/echo/error' }
    assert refusal, 'a saturated tool request must answer with a busy error'
    assert_includes refusal[:payload], 'dispatcher busy'
  end

  def test_tool_request_below_saturation_executes
    ENV['RUNES_TOOL_RPC'] = '1'
    ENV['RUNES_RPC_SECRET'] = 'vf-secret'
    d = make_dispatcher('vf-d5b')
    replied = Queue.new
    client = Object.new
    client.define_singleton_method(:publish) { |topic, payload| replied << [topic, payload] }

    # S5-4: a bare token is no longer enough — the request must carry a
    # fresh ts/nonce/mac triple. Mint it with the shared helper.
    signed = Runes::Security::RPCAuth.sign('vf-secret', 'echo', {}).merge('token' => 'vf-secret')
    payload = JSON.generate(signed)
    d.handle_tool_request(client, 'echo', payload)
    # The tool now resolves through the registry's own tools_dir, so the
    # mock WASM backend output proves execution (previously it looked in
    # <root>/tools and reported "no implementation").
    topic, body = Timeout.timeout(5) { replied.pop }
    assert_equal 'runes/tools/echo/response', topic
    assert_match(/WASM\(echo\)|no implementation/, body)

    # The same request replayed is refused ...
    d.handle_tool_request(client, 'echo', payload)
    topic, body = Timeout.timeout(5) { replied.pop }
    assert_equal 'runes/tools/echo/error', topic
    assert_includes body, 'unauthorized'

    # ... and so is a stale timestamp, even with a valid MAC.
    stale = Runes::Security::RPCAuth.sign(
      'vf-secret', 'echo', {}, ts: Time.now.to_i - 10_000
    ).merge('token' => 'vf-secret')
    d.handle_tool_request(client, 'echo', JSON.generate(stale))
    topic, = Timeout.timeout(5) { replied.pop }
    assert_equal 'runes/tools/echo/error', topic
  ensure
    ENV.delete('RUNES_TOOL_RPC')
    ENV.delete('RUNES_RPC_SECRET')
  end

  # --- L2: malformed tool-call arguments fail closed -----------------------

  class CannedHTTP
    def initialize(body)
      @body = body
    end

    def request(_req)
      resp = Class.new do
        attr_reader :code, :body

        def initialize(body)
          @code = '200'
          @body = body
        end
      end.new(@body)
      resp.define_singleton_method(:is_a?) { |k| k == Net::HTTPSuccess }
      resp
    end
  end

  def test_malformed_tool_call_arguments_reject_the_response
    settings = Object.new
    def settings.get(key, default = nil) = (@store ||= {})[key] || default
    def settings.env(key) = (@env ||= {})[key]
    def settings.set(k, v) = (@store ||= {})[k] = v
    def settings.set_env(k, v) = (@env ||= {})[k] = v
    settings.set('default_provider', 'cerebras')
    settings.set_env('CEREBRAS_API_KEY', 'k')

    llm = Runes::Core::LLMClient.new(settings)
    body = JSON.generate(
      'choices' => [{
        'finish_reason' => 'stop',
        'message' => { 'role' => 'assistant',
                       'tool_calls' => [{ 'id' => '1', 'type' => 'function',
                                          'function' => { 'name' => 'write_file',
                                                          'arguments' => '{"path": "a.rb", "content": TRUNC' } }] }
      }]
    )
    llm.define_singleton_method(:attempt_request) { |_uri, _route, _b, _t| CannedHTTP.new(body).request(nil) }
    route = llm.resolve_route
    res = llm.send(:call_openai_compatible, route, 'go')
    refute res[:ok], 'malformed tool-call arguments must fail the response (L2 fail-closed)'
    assert_includes res[:error], 'unparseable arguments'
  end

  def test_preparsed_hash_arguments_are_accepted
    settings = Object.new
    def settings.get(key, default = nil) = (@store ||= {})[key] || default
    def settings.env(key) = (@env ||= {})[key]
    def settings.set(k, v) = (@store ||= {})[k] = v
    def settings.set_env(k, v) = (@env ||= {})[k] = v
    settings.set('default_provider', 'cerebras')
    settings.set_env('CEREBRAS_API_KEY', 'k')

    llm = Runes::Core::LLMClient.new(settings)
    body = JSON.generate(
      'choices' => [{
        'finish_reason' => 'stop',
        'message' => { 'role' => 'assistant',
                       'tool_calls' => [{ 'id' => '1', 'type' => 'function',
                                          'function' => { 'name' => 'write_file',
                                                          'arguments' => { 'path' => 'a.rb' } } }] }
      }]
    )
    llm.define_singleton_method(:attempt_request) { |_uri, _route, _b, _t| CannedHTTP.new(body).request(nil) }
    route = llm.resolve_route
    res = llm.send(:call_openai_compatible, route, 'go')
    assert res[:ok], 'providers delivering parsed Hash args must not be rejected'
    assert_equal({ 'path' => 'a.rb' }, res[:tool_calls].first[:args])
  end

  # --- T5: display budgeting ------------------------------------------------

  def test_display_safe_never_exceeds_column_budget
    load File.expand_path('../bin/runes', __dir__)
    assert_equal 'abc', RunesTUI.display_safe('abc', 10)
    assert_equal 'abcde', RunesTUI.display_safe('abcdef', 5)
    # multibyte chars are replaced (1 char each after substitution)
    assert_equal '?????', RunesTUI.display_safe("日本語です", 10)
    assert_operator RunesTUI.display_safe("日本語", 2).length, :<=, 2
  end

  def test_registry_row_never_crosses_into_the_traffic_panel
    load File.expand_path('../bin/runes', __dir__)
    tui = RunesTUI.new(host: '127.0.0.1', port: 5_999, root: Dir.mktmpdir('tui-vf'))
    # Multibyte agent id (renders 2 cols per char) + an over-long tools
    # list: the row must be display-budgeted so nothing crosses into the
    # Traffic panel's columns.
    cjk_id = 'エージェント'
    long_tools = ('tool_' * 30)
    frame = tui.compose_frame({ cjk_id => { 'status' => 'online', 'tools' => long_tools } },
                              [], :build, nil, '', 0)
    refute frame.include?("\e[2;41H"), 'no registry row may write into Traffic columns'
    refute frame.include?("\e[2;40G"), 'registry rows must not jump to the old fixed tools column'
    assert_includes frame, 'tool_', 'tools text must render (budgeted after the id)'
  ensure
    root = tui.instance_variable_get(:@root)
    FileUtils.remove_entry(root) if root.to_s.start_with?(Dir.tmpdir) && Dir.exist?(root)
  end

  # --- R5: dead constant removed ----------------------------------------------

  def test_settings_has_no_dead_db_path_constant
    refute Runes::Core::Settings.const_defined?(:DB_PATH),
           'DB_PATH was dead (paths derived per-instance) — must be removed'
    assert Runes::Core::Settings.const_defined?(:ENV_PATH) # still referenced
  end

  # --- keepalive-0 safety net ---------------------------------------------------

  def test_keepalive_zero_still_bounds_mid_packet_stalls
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    # With a deadline set, a stalled mid-packet read returns :timeout
    # instead of blocking forever — and handle_client now sets a
    # deadline even for keepalive-0 clients (absolute safety net).
    a, b = UNIXSocket.pair
    b.write([0x30].pack('C')) # PUBLISH header, body never arrives
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
    assert_equal :timeout, broker.send(:read_packet, a, deadline)

    # The bound itself, not a constant compared to itself (doc5.md D5-3):
    # a keepalive-0 client must still get a finite deadline, and a client
    # that does send keepalives must get the tighter one.
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    zero = broker.send(:packet_deadline, 0) - now
    normal = broker.send(:packet_deadline, 30) - now

    assert_operator zero, :>, 0, 'keepalive 0 must still bound a mid-packet stall'
    assert_operator zero, :<=, Runes::MQTT::Broker::ABSOLUTE_PACKET_READ_S + 1
    assert_operator normal, :<, zero, 'a keepalive client must use the tighter grace window'
  ensure
    a&.close
    b&.close
  end

  class StubLLM
    def call(_prompt, **)
      { ok: true, mode: :tool_calls, tool_calls: [], raw: {} }
    end
  end
end
