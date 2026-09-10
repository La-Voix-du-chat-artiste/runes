#!/usr/bin/env ruby
# Live end-to-end demo (real LLM): /goal (2 turns) → /done → Epic →
# /plan → Mission (sidecar + markdown). Prints its own verdict and
# validates the exact artifacts from THIS run.
#
# Requires a provider key in config/.env (see config/.env.example).
require 'mqtt'
require 'json'
require 'timeout'
require 'tmpdir'
begin
require_relative '../lib/runes/mqtt/broker'
require_relative '../lib/runes/core/dispatcher'

port = 18_832
broker = Runes::MQTT::Broker.new('127.0.0.1', port)
bt = Thread.new { broker.run }
sleep 0.3

ws = Dir.mktmpdir('runes-modes')
ENV['RUNES_WORKSPACE'] = File.join(ws, 'workspace')
root = Dir.mktmpdir('runes-modes-root')
FileUtils.mkdir_p(File.join(root, 'docs', 'epics'))
FileUtils.mkdir_p(File.join(root, 'docs', 'missions'))
settings = Runes::Core::Settings.new(root: root)
dispatcher = Runes::Core::Dispatcher.new(
  { host: '127.0.0.1', port: port }, nil, nil,
  settings: settings, agent_id: 'modes-agent',
  tool_registry: Runes::Core::ToolRegistry.new(tools_dir: File.join(settings.root, 'tools'))
)

dt = Thread.new { dispatcher.start }
sleep 0.3

events = Queue.new
rt = Thread.new do
  client = MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'modes-agent')
  client.subscribe('runes/prompts/+/progress', 'runes/prompts/+/response')
  client.get { |t, m| events << [t, m] }
end
sleep 0.3

publish = lambda do |envelope|
  MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'modes-cli') do |c|
    c.publish('runes/prompts', JSON.generate(envelope))
  end
end

wait_for = lambda do |event, timeout: 240|
  deadline = Time.now + timeout
  found = nil
  Timeout.timeout(timeout) do
    loop do
      topic, msg = events.pop
      evt = (JSON.parse(msg) rescue {})
      next unless topic.end_with?('progress') && evt['event'] == event
      found = evt
      break
    end
  end
  found
end

sid = "s-#{SecureRandom.hex(3)}"
publish.call('mode' => 'goal', 'session_id' => sid, 'request_id' => "g1#{Time.now.to_i}",
             'prompt' => 'I want a tiny CLI pomodoro timer for my terminal.')
g1 = wait_for.call('conversation')
publish.call('mode' => 'goal', 'session_id' => sid, 'request_id' => "g2#{Time.now.to_i}",
             'prompt' => 'Standard pomodoro: 25-minute focus, 5-minute break, counts sessions. Ruby, stdlib only.')
g2 = wait_for.call('conversation')
publish.call('mode' => 'goal', 'session_id' => sid, 'control' => 'done', 'request_id' => "d#{Time.now.to_i}",
             'prompt' => '')
epic = wait_for.call('epic_written')

publish.call('mode' => 'plan', 'request_id' => "p#{Time.now.to_i}", 'prompt' => '')
mission = wait_for.call('mission_written')

checks = [
  [!g1.nil?, 'goal turn 1 conversed'],
  [!g2.nil?, 'goal turn 2 conversed'],
  [!epic.nil?, 'epic written (/done)'],
  [epic && File.file?(epic['path']), "epic artifact on disk: #{epic && epic['path']}"],
  [epic && File.read(epic['path']).include?('# Epic'), 'epic markdown has required sections'],
  [!mission.nil?, 'mission written (/plan)'],
  [mission && File.file?(mission['path']), "mission artifact on disk: #{mission && mission['path']}"],
  [mission && mission['todos'].to_i >= 3, 'mission has >= 3 todos']
]
checks.each { |ok, label| puts "#{ok ? 'PASS' : 'FAIL'}: #{label}" }
passed = checks.all? { |ok, _| ok }
puts passed ? 'ALL CHECKS PASSED' : 'MODES DEMO FAILED'
exit(passed ? 0 : 1)
rescue Timeout::Error => e
  puts "MODES DEMO FAILED: #{e.message}"
  exit 1
ensure
  dt&.kill
  rt&.kill
  bt&.kill
  FileUtils.remove_entry(ws) if ws.to_s.start_with?(Dir.tmpdir) && Dir.exist?(ws)
  FileUtils.remove_entry(root) if root.to_s.start_with?(Dir.tmpdir) && Dir.exist?(root)
end
