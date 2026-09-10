require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Regression tests for the second audit round:
#   * tool-RPC path runs the tool's own run.rb (not args-as-code)
#   * request_id sanitization (no topic injection)
#   * read/write byte caps
#   * Guard '#' wildcard only as final level
#   * delegation reply consumption (requester surfaces peer results)
#   * retained cap protects stored state (S-M1)
#   * concurrent prompt dispatch (bounded, off the reactive loop)
#   * journal rotation
class TestSecondAudit < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-a2')
    # D5-1: this file used `port: @port` with @port never assigned, so the
    # `mqtt` gem silently dialled the default 1883 and 15 tests errored on
    # a machine without a broker. Spawn an in-process broker on a free port
    # (same pattern as cli_tools_test.rb) and use it.
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)
    ENV['RUNES_WORKSPACE'] = @tmp
    @tools = Dir.mktmpdir('runes-a2-tools')
    FileUtils.mkdir_p(File.join(@tools, 'echo'))
    File.write(File.join(@tools, 'echo', 'card.json'),
               JSON.generate('name' => 'echo', 'description' => 'echo tool'))
    File.write(File.join(@tools, 'echo', 'capabilities.json'),
               JSON.generate('mqtt_publish' => ['runes/tools/echo/response']))
    File.write(File.join(@tools, 'echo', 'run.rb'),
               "require \"json\"\ninput = JSON.parse(STDIN.read) rescue {}\nputs input['message'].to_s")
    @settings = Runes::Core::Settings.new
    @dispatcher = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings, agent_id: 'a2-test',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: Runes::Transport::MQTT311.new(host: '127.0.0.1', port: @port, client_id: "test-#{SecureRandom.hex(4)}").connect
    )
  end

  def teardown
    @dispatcher&.instance_variable_get(:@transport)&.disconnect rescue nil
    @broker_thread&.kill
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
    FileUtils.remove_entry(@tools) if @tools && Dir.exist?(@tools)
    ENV.delete('RUNES_WORKSPACE')
    %w[RUNES_READ_CAP RUNES_WRITE_CAP].each { |k| ENV.delete(k) }
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

  # --- tool-RPC path ---------------------------------------------------

  def test_tool_rpc_executes_tool_implementation_not_args_as_code
    # A real run.rb output contains the echoed message; args-as-code
    # would produce a SyntaxError on the real backend.
    outcome = @dispatcher.execute_step({ tool: 'echo', args: { 'message' => 'rpc-test' } }, 1)
    assert_includes outcome, 'WASM(echo)'
  end

  def test_removed_execute_in_wasm_does_not_return
    refute_respond_to @dispatcher, :execute_in_wasm
  end

  # --- request_id sanitization ------------------------------------------

  def test_request_id_injection_is_neutralized
    id, = @dispatcher.parse_prompt_payload('{"request_id": "../../evil", "prompt": "x"}')
    safe = @dispatcher.send(:sanitize_request_id, id)
    assert_match(/\A[A-Za-z0-9_-]{1,32}\z/, safe)
    refute_includes safe, '/'
  end

  def test_valid_remote_request_id_is_preserved
    id, = @dispatcher.parse_prompt_payload('{"request_id": "abc-123_X", "prompt": "x"}')
    assert_equal 'abc-123_X', @dispatcher.send(:sanitize_request_id, id)
  end

  # --- read/write caps ---------------------------------------------------

  def test_read_file_enforces_cap
    big = File.join(@tmp, 'big.txt')
    File.write(big, 'x' * 3000)
    ENV['RUNES_READ_CAP'] = '1000'
    outcome = @dispatcher.execute_step({ tool: 'read_file', args: { 'path' => 'big.txt' } }, 1)
    assert_includes outcome, 'read cap'
  end

  def test_read_file_under_cap_returns_content
    File.write(File.join(@tmp, 'small.txt'), 'hello')
    ENV['RUNES_READ_CAP'] = '1000'
    outcome = @dispatcher.execute_step({ tool: 'read_file', args: { 'path' => 'small.txt' } }, 1)
    assert_equal 'hello', outcome
  end

  def test_write_file_enforces_cap
    ENV['RUNES_WRITE_CAP'] = '10'
    outcome = @dispatcher.execute_step(
      { tool: 'write_file', args: { 'path' => 'capped.txt', 'content' => 'x' * 100 } }, 1
    )
    assert_includes outcome, 'write cap'
    refute File.file?(File.join(@tmp, 'capped.txt'))
  end

  # --- Guard '#' placement ------------------------------------------------

  def test_guard_hash_wildcard_only_matches_as_final_level
    g = Runes::Capabilities::Guard.new
    # Baseline uses trailing '#'; confirm it still works end to end...
    assert g.allowed?('write_file', :fs_write, 'any/path/here.txt')
    # ...and a mid-pattern '#' is invalid per MQTT 3.1.1 §4.7.1.2, so the
    # whole filter matches NOTHING (fail-closed, agreeing with the broker).
    g2 = Runes::Capabilities::Guard.new(nil, additional_fragments: [
      { 'tools' => { 't' => { 'mqtt_publish' => ['a/#/b'] } } }
    ])
    refute g2.allowed?('t', :mqtt_publish, 'a/x/y/b'), 'mid-pattern # crossed levels'
    refute g2.allowed?('t', :mqtt_publish, 'a/#/b'), 'a malformed filter must match nothing (fail-closed)'
  end

  # --- delegation reply consumption -----------------------------------------

  class PublishingClient
    def initialize(broker)
      @broker = broker
    end

    def publish(topic, payload, retain: false)
      @broker&.publish(topic, payload, retain: retain)
    end
  end

  def test_delegation_reply_is_surfaced_on_response_topic
    surfaced = []
    @dispatcher.define_singleton_method(:publish_result) { |_c, _t, s| surfaced << s }
    message = Runes::Transport::Message.new(
      topic: "runes/agents/a2-test/tasks/req1/response",
      payload: 'peer says done',
      properties: { correlation_id: 'req1' }
    )

    @dispatcher.handle_task_reply(message)

    assert_equal 1, surfaced.size
    assert_includes surfaced.first, '[delegate a2-test/req1]'
    assert_includes surfaced.first, 'peer says done'
  end

  # Replies are filtered at the SUBSCRIPTION now: an agent only subscribes to
  # its own task-reply wildcard, so another agent's reply can never arrive.
  def test_delegation_replies_are_only_subscribed_for_this_agent
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: @settings, agent_id: 'a2-test',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: RecordingTransport.new
    )
    d.subscribe_topics
    filters = d.instance_variable_get(:@transport).subscriptions

    assert_includes filters, 'runes/agents/a2-test/tasks/+/response'
    assert(filters.none? { |f| f.include?('other-agent') },
           "must not subscribe to another agent's replies: #{filters.inspect}")
  end

  # --- concurrent prompt dispatch ---------------------------------------------

  class SlowLLM
    def call(_prompt, **)
      sleep 0.3
      { ok: true, mode: :tool_calls, tool_calls: [{ tool: 'echo', args: { 'message' => 'x' } }], raw: {} }
    end
  end

  def test_prompts_run_off_the_reactive_loop
    @dispatcher.instance_variable_set(:@llm, SlowLLM.new)
    transport = @dispatcher.instance_variable_get(:@transport)
    @dispatcher.subscribe_topics # the transport, not the caller, drives dispatch

    t0 = Time.now
    3.times { |i| transport.publish('runes/prompts', "concurrent please #{i}") }
    elapsed = Time.now - t0

    # Serial execution would take >= 0.9s; the worker pool returns at once.
    assert elapsed < 0.6, "publishing blocked for #{elapsed.round(2)}s — prompts are serial"
    sleep 0.8 # let workers finish before teardown kills threads
  end

  # --- retained cap (S-M1) ---------------------------------------------------------

  # S-M1: the retained cap must protect STORED STATE — at the cap, brand
  # new topics are refused while updates to existing topics always win a
  # slot (a hostile publisher can no longer wipe legitimate retains).
  def test_retained_cap_refuses_new_topics_but_allows_updates
    broker = Runes::MQTT::Broker.new('127.0.0.1', 0)
    (Runes::MQTT::Broker::MAX_RETAINED_COUNT).times { |i| broker.publish("cap/t#{i}", 'x', retain: true) }
    assert broker.retained.key?('cap/t0')

    # A brand-new topic at the cap is refused; oldest entries survive.
    broker.publish('cap/new', 'fresh', retain: true)
    refute broker.retained.key?('cap/new'), 'new retain must be refused at the cap'
    assert broker.retained.key?('cap/t0'), 'stored state must survive the cap'

    # An update to an existing topic still wins a slot.
    broker.publish('cap/t0', 'updated', retain: true)
    assert_equal 'updated', broker.retained['cap/t0']
  end

  # --- journal rotation ------------------------------------------------------------

  def test_journal_rotates_when_oversized
    root = Dir.mktmpdir('runes-a2-root')
    settings = Runes::Core::Settings.new(root: root)
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: settings, agent_id: 'a2-journal',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: Runes::Transport::MQTT311.new(host: '127.0.0.1', port: @port, client_id: "test-#{SecureRandom.hex(4)}").connect
    )
    path = d.journal_path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'x' * (Runes::Core::Dispatcher::JOURNAL_ROTATE_BYTES + 1))
    d.append_journal('{"status":"complete"}')
    archives = Dir.glob("#{path}.*").reject { |f| f.end_with?('.lock') }
    assert_equal 1, archives.size, 'oversized journal should rotate to one archive'
    assert_match(/journal\.jsonl\.\d{8}T\d{9}/, archives.first,
                 'rotation must use a unique, timestamped archive (B4-7)')
    assert File.file?(path)
    assert File.size(path) < Runes::Core::Dispatcher::JOURNAL_ROTATE_BYTES
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  # --- LLM retry ----------------------------------------------------------------------

  class FlakyHTTP
    attr_reader :calls

    def initialize(codes)
      @codes = codes
      @calls = 0
    end

    def request(_req)
      code = @codes[@calls] || '200'
      @calls += 1
      resp = Class.new do
        attr_reader :code, :body

        def initialize(code, body)
          @code = code
          @body = body
        end

        def is_a?(klass)
          klass == Net::HTTPSuccess && @code == '200' ? true : super
        end
      end.new(code, '{}')
      resp.define_singleton_method(:is_a?) { |k| k == Net::HTTPSuccess && @code == '200' }
      resp
    end
  end

  # request_with_retry builds a fresh connection per attempt (L4); the
  # retry policy itself is exercised by stubbing attempt_request.
  def with_retry_client(codes)
    llm = Runes::Core::LLMClient.new(@settings)
    http = FlakyHTTP.new(codes)
    route = Runes::Core::LLMClient::Route.new(
      provider: 'cerebras', base_url: 'https://api.example/v1', model: 'm',
      variation: 'high', sampling_params: {}, api_key: 'k'
    )
    uri = URI.parse('https://api.example/v1/chat/completions')
    llm.define_singleton_method(:attempt_request) do |_uri, _route, _body, _timeout|
      http.request(nil)
    end
    [llm, -> { llm.send(:request_with_retry, route, uri, '{}') }, http]
  end

  def test_llm_retries_transient_failures_then_succeeds
    _llm, run, http = with_retry_client(%w[429 500 200])
    resp = run.call
    assert_equal '200', resp.code
    assert_equal 3, http.calls
  end

  def test_llm_gives_up_after_max_retries
    _llm, run, http = with_retry_client(Array.new(10, '429'))
    resp = run.call
    assert_equal '429', resp.code
    assert_equal Runes::Core::LLMClient::MAX_RETRIES + 1, http.calls
  end
end
