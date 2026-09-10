#!/usr/bin/env ruby
# Live end-to-end demo (real LLM): /build <mission> — plan → execute →
# QA-verify per todo, sidecar + markdown ticked. Demonstrates fail-closed
# QA (weak evidence = fail) and the evidence-aware planner prompt.
# Prints its own verdict and validates artifacts from THIS run.
#
# Requires a provider key in config/.env (see config/.env.example).
require 'mqtt'
require 'json'
require 'timeout'
require 'tmpdir'
begin
require_relative '../lib/runes/mqtt/broker'
require_relative '../lib/runes/core/dispatcher'

port = 18_833
broker = Runes::MQTT::Broker.new('127.0.0.1', port)
bt = Thread.new { broker.run }
sleep 0.3

root = Dir.mktmpdir('runes-build-root')
ENV['RUNES_WORKSPACE'] = File.join(root, 'workspace')
FileUtils.mkdir_p(File.join(root, 'docs', 'missions'))
settings = Runes::Core::Settings.new(root: root)
dispatcher = Runes::Core::Dispatcher.new(
  { host: '127.0.0.1', port: port }, nil, nil,
  settings: settings, agent_id: 'build-agent',
  tool_registry: Runes::Core::ToolRegistry.new(tools_dir: File.join(settings.root, 'tools'))
)

# Seed a small mission: two todos, both verifiable with hard evidence.
mission_title = 'recovery-check'
ts = Time.now.strftime('%Y%m%d-%H%M%S')
json_path = File.join(root, 'docs', 'missions', "#{ts}-#{mission_title}.json")
File.write(json_path, JSON.generate(
  'mission_title' => mission_title,
  'todos' => [
    { 'id' => 1, 'title' => 'greeter module exists and works',
      'detail' => 'Create greeter.rb defining Greeter.hello returning exactly "hello from runes".',
      'acceptance' => 'running a command prints exactly "hello from runes"',
      'done' => false },
    { 'id' => 2, 'title' => 'greeting recorded in a file',
      'detail' => 'Save the greeting into greeting.txt in the workspace root.',
      'acceptance' => 'reading greeting.txt returns "hello from runes"',
      'done' => false }
  ]
))
File.write(json_path.sub(/\.json\z/, '.md'), "# Mission: #{mission_title}\n")

dt = Thread.new { dispatcher.start }
sleep 0.3

events = Queue.new
rt = Thread.new do
  client = MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'build-agent')
  client.subscribe('runes/prompts/+/progress', 'runes/prompts/+/response')
  client.get { |t, m| events << [t, m] }
end
sleep 0.3

MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'build-cli') do |c|
  c.publish('runes/prompts', JSON.generate(
    'mode' => 'mission', 'mission_path' => json_path,
    'request_id' => "b#{Time.now.to_i}", 'prompt' => ''
  ))
end

seen = { 'mission_started' => nil, 'mission_step_done' => [], 'mission_step_failed' => [],
         'mission_complete' => nil, 'mission_failed' => nil }
Timeout.timeout(420) do
  loop do
    topic, msg = events.pop
    evt = (JSON.parse(msg) rescue {})
    next unless topic.end_with?('progress') && evt['event']
    case evt['event']
    when 'mission_step_done' then seen['mission_step_done'] << evt['todo_id']
    when 'mission_step_failed' then seen['mission_step_failed'] << evt['todo_id']
    when 'mission_complete' then seen['mission_complete'] = evt
    when 'mission_failed' then seen['mission_failed'] = evt
    when 'mission_started' then seen['mission_started'] = evt
    end
    break if seen['mission_complete'] || seen['mission_failed']
  end
end

sidecar = JSON.parse(File.read(json_path))
greeting = File.join(root, 'workspace', 'greeting.txt')
checks = [
  [!seen['mission_started'].nil?, 'mission started'],
  [seen['mission_step_done'].size == 2, "both todos verified (done=#{seen['mission_step_done'].inspect})"],
  [sidecar['todos'].all? { |t| t['done'] == true }, 'sidecar ticked (done: true)'],
  [File.file?(greeting), 'greeting.txt exists in workspace'],
  [File.read(greeting).strip == 'hello from runes', 'greeting content verified'],
  [!seen['mission_complete'].nil?, 'mission_complete event']
]
checks.each { |ok, label| puts "#{ok ? 'PASS' : 'FAIL'}: #{label}" }
passed = checks.all? { |ok, _| ok }
puts passed ? 'ALL CHECKS PASSED' : 'BUILD DEMO FAILED'
exit(passed ? 0 : 1)
rescue Timeout::Error => e
  puts "BUILD DEMO FAILED: #{e.message}"
  exit 1
ensure
  dt&.kill
  rt&.kill
  bt&.kill
  FileUtils.remove_entry(root) if root.to_s.start_with?(Dir.tmpdir) && Dir.exist?(root)
end
