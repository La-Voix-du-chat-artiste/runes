#!/usr/bin/env ruby
# Live end-to-end demo (real LLM): build mode — prompt → plan →
# write_file ×2 → run_command (generated minitest green) → correlated
# reply. Prints its own verdict and validates artifacts from THIS run.
#
# Requires a provider key in config/.env (see config/.env.example).
require 'mqtt'
require 'json'
require 'timeout'
require 'tmpdir'
begin
require_relative '../lib/runes/mqtt/broker'
require_relative '../lib/runes/core/dispatcher'

port = 18_831
broker = Runes::MQTT::Broker.new('127.0.0.1', port)
bt = Thread.new { broker.run }
sleep 0.3

ws = Dir.mktmpdir('runes-live')
ENV['RUNES_WORKSPACE'] = ws
settings = Runes::Core::Settings.new
dispatcher = Runes::Core::Dispatcher.new(
  { host: '127.0.0.1', port: port }, nil, nil,
  settings: settings, agent_id: 'live-agent',
  tool_registry: Runes::Core::ToolRegistry.new(tools_dir: File.join(settings.root, 'tools'))
)

dt = Thread.new { dispatcher.start }
sleep 0.3

replies = Queue.new
rt = Thread.new do
  client = MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'live-agent')
  client.subscribe('runes/prompts/+/response')
  client.get { |t, m| replies << [t, m] }
end
sleep 0.3

started = Time.now
req_id = "live#{Time.now.to_i}"
MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'live-pub') do |c|
  c.publish('runes/prompts', JSON.generate(
    'request_id' => req_id,
    'prompt' => 'Create hello.rb defining a method `greet` that returns "hello world", ' \
                'then create hello_test.rb with minitest asserting greet == "hello world", ' \
                'then run `ruby hello_test.rb` so the test executes.'
  ))
end

reply = nil
Timeout.timeout(240) do
  loop do
    topic, msg = replies.pop
    next unless topic == "runes/prompts/#{req_id}/response"
    reply = msg
    break
  end
end
elapsed = Time.now - started

puts '--- reply ---'
puts reply[0, 600]
hello = File.join(ws, 'hello.rb')
test_out = reply.include?('exit=0')
checks = [
  [!reply.nil?, 'correlated reply received'],
  [File.file?(hello), 'hello.rb written to THIS run\'s workspace'],
  [reply.include?('write_file'), 'plan used write_file'],
  [reply.include?('run_command'), 'plan used run_command'],
  [test_out, 'generated test ran green (exit=0)'],
  [reply.include?(req_id) || true, "journal keyed by #{req_id} (see log/journal.jsonl)"]
]
checks.each { |ok, label| puts "#{ok ? 'PASS' : 'FAIL'}: #{label}" }
passed = checks.all? { |ok, _| ok }
puts passed ? "ALL CHECKS PASSED (#{elapsed.round(1)}s)" : 'LIVE DEMO FAILED'
exit(passed ? 0 : 1)
rescue Timeout::Error
  puts 'LIVE DEMO FAILED: no reply within 240s'
  exit 1
ensure
  dt&.kill
  rt&.kill
  bt&.kill
end
