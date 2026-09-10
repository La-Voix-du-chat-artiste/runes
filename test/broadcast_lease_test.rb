require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Envelope identity: plain prompts derived from the same text must share a
# request id, the default workspace must be deterministic (project-local
# workspace/, never Dir.pwd), and a hostile request_id must be sanitized to a
# stable fallback.
#
# History: this file used to spawn a real broker and set
# RUNES_CLAIM_WINDOW_S to test the claim/lease protocol. The protocol was
# deleted in 0.3.0 (MQTT 5 shared subscriptions replaced it), no test here
# ever used the broker, and the knob had been dead for a release — so both
# are gone (doc5.md D5-3/B7).
class TestBroadcastLease < Minitest::Test
  def setup
    @ws_a = Dir.mktmpdir('lease-a')
    @ws_b = Dir.mktmpdir('lease-b')
    @settings = Runes::Core::Settings.new
    @port = find_free_port
  end

  def teardown
    [@ws_a, @ws_b].each { |d| FileUtils.remove_entry(d) if d && Dir.exist?(d) }
  end

  class MarkerLLM
    def initialize(marker)
      @marker = marker
    end

    def call(_prompt, **)
      { ok: true, mode: :tool_calls,
        tool_calls: [{ tool: 'write_file', args: { 'path' => 'marker.txt', 'content' => @marker } }],
        raw: {} }
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

  def make_dispatcher(agent_id, workspace)
    ENV['RUNES_WORKSPACE'] = workspace
    d = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: Dir.mktmpdir('lease-tools')),
      transport: RecordingTransport.new
    )
    d.instance_variable_set(:@llm, MarkerLLM.new(agent_id))
    d
  end

  def test_plain_prompts_share_a_request_id_via_prompt_digest
    d = make_dispatcher('digest-agent', @ws_a)
    env1 = d.parse_envelope('run the tests')
    env2 = d.parse_envelope('run the tests')

    refute env1[:from_envelope]
    assert_equal d.send(:prompt_digest_id, 'run the tests'), env1[:request_id]
    assert_equal 'run the tests', env1[:prompt]
    assert_equal env1[:request_id], env2[:request_id],
                 'same prompt text must derive the same id on every agent'
  end

  def test_workspace_defaults_to_project_local_dir
    ENV.delete('RUNES_WORKSPACE')
    root = Dir.mktmpdir('ws-default')
    settings = Runes::Core::Settings.new(root: root)
    assert_equal File.join(root, 'workspace'), settings.workspace_root,
                 'workspace default must be deterministic, never Dir.pwd'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
    ENV['RUNES_WORKSPACE'] = @ws_a
  end

  # D1: an invalid client request_id must degrade to a DETERMINISTIC id
  # — a random one makes every agent claim a different topic and all of
  # them execute.
  def test_invalid_envelope_request_id_derives_deterministic_fallback
    d = make_dispatcher('det-agent', @ws_a)
    id1 = d.parse_envelope('{"request_id": "../../evil", "prompt": "x"}')[:request_id]
    id2 = d.parse_envelope('{"request_id": "../../evil", "prompt": "x"}')[:request_id]
    assert_equal id1, id2, 'sanitized fallback id must be deterministic across agents'
    assert_match(/\A[A-Za-z0-9_-]{1,32}\z/, id1)
    refute_includes id1, '/'
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
