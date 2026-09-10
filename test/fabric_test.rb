require "timeout"
require "json"
require "tmpdir"
require_relative "test_helper"
require_relative "../lib/runes/transport"
require_relative "../lib/runes/a2a"
require_relative "../lib/runes/security"

# The 0.3 fabric: transport-agnostic fan-out, exactly-once work via shared
# subscriptions (no claim protocol), A2A-over-MQTT discovery/tasks, and
# optional signed envelopes.
class FabricTest < Minitest::Test
  class CountingLLM
    attr_reader :calls

    def initialize
      @calls = Queue.new
    end

    def call(prompt, **_options)
      @calls << prompt
      { ok: true, mode: :content, content: '{"steps":[]}', raw: {} }
    end

    def chat(_messages, **_options)
      { ok: true, mode: :content, content: '{}', raw: {} }
    end
  end

  def setup
    @tmp = Dir.mktmpdir('fabric')
    @tools = Dir.mktmpdir('fabric-tools')
    @settings = Runes::Core::Settings.new(root: @tmp)
    @hub = Runes::Transport::InProcess::Hub.new(name: "fabric-#{object_id}")
    @dispatchers = []
  end

  def teardown
    @dispatchers.each { |d| d.instance_variable_get(:@transport)&.disconnect }
    [@tmp, @tools].each { |dir| FileUtils.remove_entry(dir) if dir && Dir.exist?(dir) }
    %w[RUNES_REQUIRE_SIGNATURES RUNES_TRUST_DIR].each { |k| ENV.delete(k) }
  end

  def make_dispatcher(agent_id, llm: CountingLLM.new)
    transport = Runes::Transport::InProcess.new(hub: @hub, client_id: agent_id).connect
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: transport
    )
    d.instance_variable_set(:@llm, llm)
    @dispatchers << d
    d
  end

  def envelope(request_id, prompt, mode: 'build')
    JSON.generate('request_id' => request_id, 'prompt' => prompt, 'mode' => mode)
  end

  # --- P0.2: exactly-once work distribution -------------------------------

  def test_a_prompt_is_executed_by_exactly_one_agent_in_the_group
    llm_a = CountingLLM.new
    llm_b = CountingLLM.new
    a = make_dispatcher('fabric-a', llm: llm_a)
    b = make_dispatcher('fabric-b', llm: llm_b)
    a.subscribe_topics
    b.subscribe_topics

    a.instance_variable_get(:@transport).publish('runes/prompts', envelope('req-once', 'do the thing'))

    calls = []
    Timeout.timeout(3) do
      loop do
        calls << llm_a.calls.pop unless llm_a.calls.empty?
        calls << llm_b.calls.pop unless llm_b.calls.empty?
        break if calls.size >= 1
      end
    end
    sleep 0.3 # give the other agent a chance to (wrongly) run too

    total = calls.size + llm_a.calls.size + llm_b.calls.size
    assert_equal 1, total,
                 'a shared subscription must deliver the prompt to exactly one agent (claim protocol retired)'
  end

  def test_a_transport_that_cannot_do_shared_groups_refuses_fail_closed
    transport = Runes::Transport::MQTT311.new(host: '127.0.0.1', port: 1)
    assert_raises(Runes::Transport::Unsupported) do
      transport.subscribe('runes/prompts', group: 'workers') { |_m| }
    end
    refute transport.supports_groups?
  end

  def test_the_dispatcher_falls_back_to_single_consumer_mode_only_when_allowed
    ENV['RUNES_REQUIRE_SHARED_SUBSCRIPTIONS'] = '1'
    transport = Class.new do
      def initialize = @subs = []
      def connect = self
      def connected? = true
      def describe = 'NoGroups'
      def supports_groups? = false
      def subscribe(filter, **_options, &_block)
        raise Runes::Transport::Unsupported, 'no shared subscriptions here' if _options[:group]

        @subs << filter
      end
    end.new

    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 0 }, nil, nil,
      settings: @settings, agent_id: 'strict-agent',
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: transport
    )
    assert_raises(Runes::Transport::Unsupported) { d.subscribe_work }
  ensure
    ENV.delete('RUNES_REQUIRE_SHARED_SUBSCRIPTIONS')
  end

  # --- P0.3: A2A discovery + tasks ----------------------------------------

  def test_an_agent_publishes_an_a2a_card_and_peers_discover_it
    a = make_dispatcher('fabric-card-a')
    b = make_dispatcher('fabric-card-b')
    b.subscribe_a2a
    a.announce_agent_card

    peer = b.peers.find { |p| p[:agent_id] == 'fabric-card-a' }
    refute_nil peer, "expected the retained A2A card to register the peer, got #{b.peers.inspect}"
    assert_includes peer[:skills], 'run_command'
    assert_equal 'online', peer[:status]
  end

  def test_the_a2a_card_uses_the_standard_fields_with_runes_under_x_runes
    card = make_dispatcher('fabric-card-shape').a2a_agent_card

    assert_equal '0.3.0', card['protocolVersion']
    assert_equal 'MQTT', card['preferredTransport']
    assert card['skills'].any? { |s| s['id'] == 'write_file' }
    assert_equal 'runes.dispatcher', card.dig('x-runes', 'kind')
    assert_includes card.dig('x-runes', 'tools'), 'run_command'
  end

  def test_an_a2a_task_is_executed_and_answered_on_its_response_topic
    llm = CountingLLM.new
    d = make_dispatcher('fabric-task-target', llm: llm)
    d.subscribe_a2a

    watcher = Runes::Transport::InProcess.new(hub: @hub, client_id: 'a2a-watcher').connect
    replies = Queue.new
    watcher.subscribe('runes/prompts/task-9/response') { |message| replies << message.payload }

    task = Runes::A2A::Task.request(prompt: 'a2a please', task_id: 'task-9')
    d.instance_variable_get(:@transport).publish(
      Runes::A2A.task_topic(org: d.instance_variable_get(:@a2a_org),
                            unit: d.instance_variable_get(:@a2a_unit),
                            agent_id: 'fabric-task-target'),
      JSON.generate(task),
      properties: { response_topic: "runes/prompts/task-9/response", correlation_id: 'task-9' }
    )

    plan = Timeout.timeout(3) { llm.calls.pop }
    assert_equal 'a2a please', plan
    # D5-3: this test used to be guarded by a method that exists nowhere, so
    # it never asserted the reply. Require the a2a-status update on the
    # response topic instead.
    status = Timeout.timeout(3) { JSON.parse(replies.pop) }
    assert_equal 'working', status.dig('status', 'state'),
                 'the requester must get an a2a-status update on its response topic'
  ensure
    watcher&.disconnect
  end

  # --- S5-5/S5-6: attacker-controlled reply topics and reflected payloads ---

  def test_reply_topics_are_validated
    d = make_dispatcher('fabric-reply')
    assert_equal 'runes/prompts/x/response', d.safe_reply_topic('runes/prompts/x/response')
    assert_nil d.safe_reply_topic('evil/x'), 'outside the runes/ namespace'
    assert_nil d.safe_reply_topic('runes/prompts/+/response'), 'wildcard'
    assert_nil d.safe_reply_topic('runes/prompts/#'), 'wildcard'
    assert_nil d.safe_reply_topic('$SYS/runes/x'), '$-topic'
    assert_nil d.safe_reply_topic('')
  end

  def test_a_hostile_response_topic_is_not_used_as_a_publish_target
    llm = CountingLLM.new
    d = make_dispatcher('fabric-hostile-reply', llm: llm)
    d.subscribe_a2a

    watcher = Runes::Transport::InProcess.new(hub: @hub, client_id: 'hostile-watcher').connect
    fallback = Queue.new
    watcher.subscribe('runes/prompts/task-evil/response') { |message| fallback << message.payload }

    task = Runes::A2A::Task.request(prompt: 'x', task_id: 'task-evil')
    d.instance_variable_get(:@transport).publish(
      Runes::A2A.task_topic(org: d.instance_variable_get(:@a2a_org),
                            unit: d.instance_variable_get(:@a2a_unit),
                            agent_id: 'fabric-hostile-reply'),
      JSON.generate(task),
      properties: { response_topic: 'evil/agents/other/card', correlation_id: 'task-evil' }
    )

    Timeout.timeout(3) { llm.calls.pop }
    payload = Timeout.timeout(3) { fallback.pop }
    assert_equal 'working', JSON.parse(payload).dig('status', 'state'),
                 'an invalid response topic must fall back to the correlated runes/ topic'
  ensure
    watcher&.disconnect
  end

  def test_task_replies_are_sanitized_and_bounded_before_reflection
    d = make_dispatcher('fabric-reply-bound')
    surfaced = []
    d.define_singleton_method(:publish_result) { |_c, _t, summary| surfaced << summary }
    message = Runes::Transport::Message.new(
      topic: 'runes/agents/fabric-reply-bound/tasks/r1/response',
      payload: 'A' * 20_000,
      properties: { correlation_id: 'r1' }
    )

    d.handle_task_reply(message)

    assert_equal 1, surfaced.size
    assert_includes surfaced.first, '[delegate fabric-reply-bound/r1]'
    assert_operator surfaced.first.bytesize, :<, 20_000,
                    'a peer payload must be bounded before it is reflected'
  end

  # --- P1.5: signatures ---------------------------------------------------

  def test_unsigned_envelopes_are_refused_when_signatures_are_required
    with_signing do |trust_dir, client|
      d = make_dispatcher('fabric-signed')
      replied = []
      d.define_singleton_method(:publish_result) { |_c, topic, body| replied << [topic, body] }

      d.handle_incoming_broadcast(
        Runes::Transport::Message.new(topic: 'runes/prompts', payload: envelope('req-unsigned', 'nope'))
      )

      assert_equal 1, replied.size
      assert_includes replied.first.last, 'unsigned or invalid envelope'
      assert_empty d.instance_variable_get(:@llm).calls, 'an unverified prompt must never reach the planner'
      refute_nil client
      refute_nil trust_dir
    end
  end

  def test_a_signed_envelope_from_a_trusted_peer_is_accepted
    with_signing do |_trust_dir, client|
      d = make_dispatcher('fabric-signed-ok')
      signed = Runes::Security::Envelope.sign(
        { 'request_id' => 'req-signed', 'prompt' => 'signed please', 'mode' => 'build' }, client
      )

      d.handle_incoming_broadcast(
        Runes::Transport::Message.new(topic: 'runes/prompts', payload: JSON.generate(signed))
      )

      plan = Timeout.timeout(3) { d.instance_variable_get(:@llm).calls.pop }
      assert_equal 'signed please', plan
    end
  end

  # S5-1: the delegated-task path was never gated, so an unsigned payload
  # reached the planner with RUNES_REQUIRE_SIGNATURES=1.
  def test_unsigned_delegated_tasks_are_refused_when_signatures_are_required
    with_signing do |_trust_dir, _client|
      llm = CountingLLM.new
      d = make_dispatcher('fabric-signed-del', llm: llm)
      replied = []
      d.define_singleton_method(:publish_result) { |_c, topic, body| replied << [topic, body] }

      d.handle_delegated_task(
        JSON.generate('prompt' => 'nope', 'from' => 'peer-ok', 'request_id' => 'r1')
      )

      refute_empty replied, 'the refusal must be answered'
      assert_includes replied.last.last, 'unsigned or invalid envelope'
      assert_empty llm.calls, 'an unverified delegated task must never reach the planner'
    end
  end

  def test_signed_delegated_tasks_are_accepted
    with_signing do |_trust_dir, client|
      llm = CountingLLM.new
      d = make_dispatcher('fabric-signed-del-ok', llm: llm)
      signed = Runes::Security::Envelope.sign(
        { 'prompt' => 'signed delegation', 'from' => 'peer-client', 'request_id' => 'r2' }, client
      )

      d.handle_delegated_task(JSON.generate(signed))

      assert_equal 'signed delegation', Timeout.timeout(3) { llm.calls.pop }
    end
  end

  # S5-1: A2A is on by default, so the subscribed task wildcard was the
  # easiest way in.
  def test_unsigned_a2a_tasks_are_refused_when_signatures_are_required
    with_signing do |_trust_dir, _client|
      llm = CountingLLM.new
      d = make_dispatcher('fabric-signed-a2a', llm: llm)
      replied = []
      d.define_singleton_method(:publish_result) { |_c, topic, body| replied << [topic, body] }

      task = Runes::A2A::Task.request(prompt: 'nope', task_id: 'task-x')
      d.handle_a2a_task(
        Runes::Transport::Message.new(
          topic: Runes::A2A.task_topic(org: d.instance_variable_get(:@a2a_org),
                                       unit: d.instance_variable_get(:@a2a_unit),
                                       agent_id: 'fabric-signed-a2a'),
          payload: JSON.generate(task),
          properties: { response_topic: 'runes/prompts/task-x/response', correlation_id: 'task-x' }
        )
      )

      refute_empty replied, 'the refusal must be answered'
      assert_includes replied.last.last, 'unsigned or invalid envelope'
      assert_empty llm.calls, 'an unverified A2A task must never reach the planner'
    end
  end

  def test_signed_a2a_tasks_are_accepted
    with_signing do |_trust_dir, client|
      llm = CountingLLM.new
      d = make_dispatcher('fabric-signed-a2a-ok', llm: llm)
      task = Runes::A2A::Task.request(prompt: 'signed a2a', task_id: 'task-y')
      # The sender signs with ITS identity; the trust store here holds the
      # client key, so build the wrapper the way a peer would.
      signed = Runes::Security::Envelope.sign(
        { 'a2a' => JSON.generate(task), 'request_id' => 'task-y' }, client
      )

      d.handle_a2a_task(
        Runes::Transport::Message.new(
          topic: Runes::A2A.task_topic(org: d.instance_variable_get(:@a2a_org),
                                       unit: d.instance_variable_get(:@a2a_unit),
                                       agent_id: 'fabric-signed-a2a-ok'),
          payload: JSON.generate(signed),
          properties: { response_topic: 'runes/prompts/task-y/response', correlation_id: 'task-y' }
        )
      )

      assert_equal 'signed a2a', Timeout.timeout(3) { llm.calls.pop }
    end
  end

  def test_a2a_task_payload_is_signed_when_signatures_are_required
    with_signing do |_trust_dir, _client|
      d = make_dispatcher('fabric-a2a-signer')
      task = Runes::A2A::Task.request(prompt: 'wrapped', task_id: 'task-w')
      data = JSON.parse(d.a2a_task_payload(task, 'task-w'))

      assert_equal d.instance_variable_get(:@identity).fingerprint, data['kid']
      parsed = Runes::A2A::Task.parse(data['a2a'])
      assert_equal 'wrapped', Runes::A2A::Task.prompt_from(parsed)
    end
  end

  private

  # Enables signature enforcement with a throwaway trust store holding one
  # client key, and yields that trust dir + identity.
  def with_signing
    ENV['RUNES_REQUIRE_SIGNATURES'] = '1'
    trust_dir = File.join(@tmp, 'trust')
    FileUtils.mkdir_p(trust_dir)
    client = Runes::Security::Identity.load_or_create(agent_id: 'peer-client',
                                                      dir: File.join(@tmp, 'client-keys'))
    File.write(File.join(trust_dir, 'peer-client.pem'), client.public_key_pem)
    ENV['RUNES_TRUST_DIR'] = trust_dir
    yield trust_dir, client
  end
end
