require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Full-stack dispatcher integration: the agent card and status are
# published as retained messages at boot, so late-joining observers
# discover the fleet without polling.
class TestDispatcherIntegration < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-int')
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)

    ENV['RUNES_WORKSPACE'] = @tmp
    @tools = Dir.mktmpdir('runes-int-tools')
    @settings = Runes::Core::Settings.new
    @dispatcher = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: @port }, nil, nil,
      settings: @settings, agent_id: "it-#{self.class.name}-#{rand(1000)}",
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: Runes::Transport::MQTT311.new(host: '127.0.0.1', port: @port, client_id: "test-#{SecureRandom.hex(4)}").connect
    )
    @dispatcher_thread = Thread.new { @dispatcher.start }
  end

  def teardown
    @dispatcher_thread&.kill
    @broker_thread&.kill
    [@tmp, @tools].each { |d| FileUtils.remove_entry(d) if d && Dir.exist?(d) }
    ENV.delete('RUNES_WORKSPACE')
  end

  def test_agent_card_is_published_as_retained
    payload = fetch_retained("runes/agents/#{@dispatcher.agent_id}/card")
    card = JSON.parse(payload)
    assert_equal 'runes.dispatcher', card['kind']
    assert_equal @dispatcher.agent_id, card['name']
    assert card['wasm_backend']
    assert_includes Array(card['tools']), 'write_file'
  end

  def test_status_topic_is_online_after_boot
    assert_equal 'online', fetch_retained("runes/agents/#{@dispatcher.agent_id}/status")
  end

  def test_agent_card_survives_late_subscription
    sleep 0.3 # boot completes
    payload = fetch_retained("runes/agents/#{@dispatcher.agent_id}/card")
    refute_nil payload, 'a late subscriber must still receive the retained card'
  end

  private

  def fetch_retained(topic, timeout: 5)
    client = MQTT::Client.connect('127.0.0.1', @port, client_id: "obs-#{rand(10_000)}")
    client.subscribe(topic)
    result = nil
    Timeout.timeout(timeout) do
      client.get do |_t, msg|
        result = msg
        break
      end
    end
    result
  ensure
    client&.disconnect rescue nil
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
end
