require 'minitest/autorun'
require 'stringio'
require 'json'
require 'timeout'
require 'rbconfig'

require_relative '../lib/runes/mcp/protocol'
require_relative '../lib/runes/mcp/tool_provider'
require_relative '../lib/runes/mcp/server'
require_relative '../lib/runes/mcp/client'

# Hermetic MCP tests: no broker, no SQLite, no network. The only subprocess
# is the tmp/mcp_echo_server.rb fixture (same Ruby, no gems), and it is
# always closed in teardown so a failing assertion cannot leak a child.
#
# These tests deliberately do NOT load test_helper.rb: that helper boots the
# dispatcher/broker tree, which is irrelevant here and would make a
# stdlib-only feature test depend on the whole harness.
class MCPTest < Minitest::Test
  # In test/support/, NOT tmp/: that directory is gitignored, so the whole
  # MCP client suite used to fail in a fresh clone or CI (doc5.md T5-9).
  ECHO_SERVER = File.expand_path('support/mcp_echo_server.rb', __dir__)

  # ---------- protocol ----------

  def test_protocol_round_trip
    message = Runes::MCP::Protocol.response(7, { 'tools' => [] })
    assert_equal message, Runes::MCP::Protocol.decode(Runes::MCP::Protocol.encode(message))
    assert_equal '2.0', message['jsonrpc']
  end

  def test_protocol_rejects_non_objects_and_malformed_json
    assert_nil Runes::MCP::Protocol.decode('not json at all')
    assert_nil Runes::MCP::Protocol.decode('[1,2,3]')
    assert_nil Runes::MCP::Protocol.decode('"a string"')
    assert_nil Runes::MCP::Protocol.decode('')
  end

  def test_error_response_carries_code_and_message
    response = Runes::MCP::Protocol.error_response(nil, Runes::MCP::Protocol::PARSE_ERROR)
    assert_nil response['id']
    assert_equal(-32_700, response['error']['code'])
    assert_equal 'Parse error', response['error']['message']
  end

  def test_request_distinguishes_notifications_from_id_null
    assert Runes::MCP::Protocol.request?('id' => 1, 'method' => 'ping')
    assert Runes::MCP::Protocol.request?('id' => nil, 'method' => 'ping')
    refute Runes::MCP::Protocol.request?('method' => 'notifications/initialized')
  end

  def test_version_negotiation_prefers_supported_client_version
    assert_equal '2024-11-05', Runes::MCP::Protocol.negotiate_version('2024-11-05')
    assert_equal Runes::MCP::Protocol::LATEST_VERSION,
                 Runes::MCP::Protocol.negotiate_version('1999-01-01')
    assert_equal Runes::MCP::Protocol::LATEST_VERSION, Runes::MCP::Protocol.negotiate_version(nil)
  end

  def test_truncate_bytes_marks_truncation
    assert_equal 'abc', Runes::MCP::Protocol.truncate_bytes('abc', 10)
    out = Runes::MCP::Protocol.truncate_bytes('abcdefghij', 4)
    assert out.start_with?('abcd')
    assert_includes out, 'truncated'
  end

  # ---------- provider ----------

  def test_provider_normalizes_openai_shaped_descriptors
    provider = Runes::MCP::ToolProvider.from_lists(
      tools: [{ type: 'function', function: { name: 'echo', description: 'd', parameters: { 'type' => 'object' } } }],
      callable: ->(_name, _args) { 'ok' }
    )
    card = provider.tool_descriptors.first
    assert_equal 'echo', card['name']
    assert_equal 'd', card['description']
    assert_equal 'object', card['inputSchema']['type']
  end

  def test_provider_wraps_string_results_and_caps_output
    provider = Runes::MCP::ToolProvider.from_lists(
      tools: [{ 'name' => 'huge' }],
      callable: ->(_name, _args) { 'x' * 100 },
      max_output_bytes: 10
    )
    result = provider.call('huge', {})
    refute result['isError']
    assert_equal 'text', result['content'].first['type']
    assert_operator result['content'].first['text'].bytesize, :<, 100
  end

  def test_provider_marks_executor_error_strings_as_errors
    provider = Runes::MCP::ToolProvider.from_lists(
      tools: [{ 'name' => 'run_command' }],
      callable: ->(_n, _a) { 'Error: capability denied (exec)' }
    )
    result = provider.call('run_command', {})
    assert result['isError'], 'a harness "Error: ..." string must map to isError'
    assert_includes result['content'].first['text'], 'capability denied'
  end

  def test_provider_unknown_tool_is_an_error_result_not_an_raise
    provider = Runes::MCP::ToolProvider.from_lists(tools: [], callable: ->(_n, _a) { 'nope' })
    result = provider.call('ghost', {})
    assert result['isError']
    assert_includes result['content'].first['text'], 'unknown tool'
  end

  # ---------- server (in-memory streams) ----------

  def test_server_initialize_list_call_and_errors
    provider = Runes::MCP::ToolProvider.from_lists(
      tools: [{
        'name' => 'echo',
        'description' => 'Echo',
        'inputSchema' => { 'type' => 'object', 'properties' => { 'message' => { 'type' => 'string' } } }
      }],
      callable: ->(_name, args) { "echo:#{args['message']}" }
    )

    input = StringIO.new(<<~LINES)
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"t","version":"1"}}}
      {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
      {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
      {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"}}}
      {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ghost","arguments":{}}}
      {"jsonrpc":"2.0","id":5,"method":"nope","params":{}}
      {this is not json
      {"jsonrpc":"2.0","id":6,"method":"ping","params":{}}
    LINES
    output = StringIO.new
    server = Runes::MCP::Server.new(provider: provider, io: capture_only(input, output))

    server.serve

    responses = parse_lines(output.string)
    # Notification produced no response; every request did.
    assert_equal [1, 2, 3, 4, 5, nil, 6], responses.map { |message| message['id'] }

    init = responses[0]['result']
    assert_equal '2024-11-05', init['protocolVersion']
    assert_equal({ 'tools' => {} }, init['capabilities'])
    assert_equal 'runes-mcp', init['serverInfo']['name']

    assert_equal 'echo', responses[1]['result']['tools'].first['name']

    call = responses[2]['result']
    refute call['isError']
    assert_equal 'echo:hi', call['content'].first['text']

    unknown = responses[3]['result']
    assert unknown['isError']
    assert_includes unknown['content'].first['text'], 'unknown tool'

    assert_equal(-32_601, responses[4]['error']['code'])
    assert_equal(-32_700, responses[5]['error']['code'])
    assert_equal({}, responses[6]['result'])
  end

  def test_server_malformed_json_does_not_stop_the_loop
    provider = Runes::MCP::ToolProvider.from_lists(tools: [], callable: ->(_n, _a) { '' })
    input = StringIO.new("garbage\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n")
    output = StringIO.new
    server = Runes::MCP::Server.new(provider: provider, io: capture_only(input, output))
    server.serve
    responses = parse_lines(output.string)
    assert_equal(-32_700, responses.first['error']['code'])
    assert_equal 9, responses.last['id']
  end

  def test_server_unknown_id_response_is_not_sent_for_notifications
    provider = Runes::MCP::ToolProvider.from_lists(tools: [], callable: ->(_n, _a) { '' })
    output = StringIO.new
    server = Runes::MCP::Server.new(provider: provider, io: capture_only(StringIO.new(''), output))
    assert_nil server.dispatch('jsonrpc' => '2.0', 'method' => 'notifications/initialized')
    assert_equal '', output.string
  end

  # ---------- client (real subprocess) ----------

  def test_client_initialize_list_and_call_round_trip
    client = build_client
    init = client.initialize_session
    assert_equal '2025-06-18', init['protocolVersion']
    assert_equal 'mcp-echo-fixture', init['serverInfo']['name']

    tools = client.tools
    assert_equal 1, tools.size
    assert_equal 'echo', tools.first['name']
    assert tools.first['inputSchema'].is_a?(Hash)

    result = client.call_tool('echo', { 'message' => 'hello mcp' })
    refute result['isError']
    assert_equal 'hello mcp', result['content'].first['text']

    missing = client.call_tool('ghost', {})
    assert missing['isError']
    assert_includes missing['content'].first['text'], 'unknown tool'
  ensure
    client&.close
  end

  def test_client_drains_stderr_without_deadlocking
    client = build_client
    client.initialize_session
    # The fixture writes "[mcp_echo_server] ready" to stderr before serving.
    Timeout.timeout(5) { sleep 0.05 until client.stderr_tail.include?('ready') }
    assert_includes client.stderr_tail, 'ready'
  ensure
    client&.close
  end

  def test_client_timeout_is_clear_and_does_not_kill_the_client
    # `hang: true` makes the fixture never answer, so the client's bounded
    # wait is exercised deterministically (no timing race on a real sleep).
    # Generous construction timeout: the handshake runs on a busy machine
    # and must not be what times out. Only the hanging call is bounded.
    client = build_client
    client.initialize_session
    error = assert_raises(Timeout::Error) do
      client.call_tool('echo', { 'message' => 'x', 'hang' => true }, timeout: 0.3)
    end
    assert_includes error.message, 'timed out'
    assert_includes error.message, 'id='
    # Timeouts must not wedge the CLIENT: a fresh session still works (the
    # hung fixture's loop is blocked, so it cannot prove this).
    client.close
    good = build_client
    good.initialize_session
    result = good.call_tool('echo', { 'message' => 'after' })
    assert_equal 'after', result['content'].first['text']
  ensure
    client&.close
    good&.close
  end

  def test_client_rejects_an_id_it_never_sent
    client = build_client
    client.initialize_session
    # A response for an id nobody is waiting on must be dropped, never
    # delivered to the next caller (which would return the wrong result).
    client.instance_variable_get(:@stdin).write(
      JSON.generate('jsonrpc' => '2.0', 'id' => 424_242, 'result' => { 'poison' => true }) + "\n"
    )
    client.instance_variable_get(:@stdin).flush

    result = client.call_tool('echo', { 'message' => 'clean' })
    assert_equal 'clean', result['content'].first['text']
  ensure
    client&.close
  end

  def test_client_close_is_clean_and_idempotent
    client = build_client
    client.initialize_session
    client.close
    assert client.closed?
    client.close # second close must not raise
    assert_raises(IOError) { client.request('ping', {}) }
  end

  # Two threads starting a fresh client used to spawn two servers and leak
  # the first one (doc5.md T5-10). One reader thread is the observable.
  def test_concurrent_start_spawns_exactly_one_server
    client = Runes::MCP::Client.new(command: RbConfig.ruby,
                                    args: ['-I', File.expand_path('../lib', __dir__), ECHO_SERVER],
                                    name: 'concurrent-test')

    threads = 3.times.map { Thread.new { client.send(:start) } }
    threads.each(&:join)

    assert client.open?, 'the client must be usable afterwards'
    readers = Thread.list.count { |th| th.name == 'runes-mcp-reader' }
    assert_equal 1, readers, "exactly one server/reader must exist, found #{readers}"
  ensure
    client&.close
  end

  private

  # The server writes to `output` but must read from the injected input;
  # StringIO can do both, but keeping the roles explicit documents intent.
  def capture_only(input, output)
    reader = Class.new do
      define_method(:gets) { input.gets }
      define_method(:write) { |data| output.write(data) }
      define_method(:flush) { output.flush }
    end
    reader.new
  end

  def parse_lines(text)
    text.to_s.each_line.filter_map do |line|
      line = line.strip
      next if line.empty?

      JSON.parse(line)
    end
  end

  def build_client(timeout_s: 5.0)
    Runes::MCP::Client.new(
      command: RbConfig.ruby,
      args: ['-I', File.expand_path('../lib', __dir__), ECHO_SERVER],
      name: 'runes-mcp-test',
      version: '0.0.1',
      timeout_s: timeout_s
    )
  end
end
