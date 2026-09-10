#!/usr/bin/env ruby
# Offline smoke test: embedded broker + dispatcher with the mock
# backend and a STUB planner — no API key, no network. Verifies the
# full pipeline: prompt → plan → guarded tools → correlated reply +
# journal entry.
require 'mqtt'
require 'json'
require 'timeout'
require 'tmpdir'
begin
require_relative '../lib/runes/mqtt/broker'
require_relative '../lib/runes/core/dispatcher'

port = 18_830
broker = Runes::MQTT::Broker.new('127.0.0.1', port)
bt = Thread.new { broker.run }
sleep 0.3

ws = Dir.mktmpdir('runes-smoke')
ENV['RUNES_WORKSPACE'] = ws
settings = Runes::Core::Settings.new
dispatcher = Runes::Core::Dispatcher.new(
  { host: '127.0.0.1', port: port }, nil, nil,
  settings: settings, agent_id: 'smoke-agent',
  tool_registry: Runes::Core::ToolRegistry.new(tools_dir: File.join(settings.root, 'tools'))
)

# Stub planner: a deterministic 2-step plan (no LLM key needed).
stub = Object.new
stub.define_singleton_method(:call) do |_prompt, **|
  { ok: true, mode: :tool_calls,
    tool_calls: [
      { tool: 'write_file', args: { 'path' => 'smoke.txt', 'content' => "smoke ok\n" } },
      { tool: 'read_file', args: { 'path' => 'smoke.txt' } }
    ], raw: {} }
end
dispatcher.instance_variable_set(:@llm, stub)

dt = Thread.new { dispatcher.start }
sleep 0.3

replies = Queue.new
rt = Thread.new do
  client = MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'smoke-agent')
  client.subscribe('runes/prompts/+/response', 'runes/prompts/+/progress')
  client.get { |t, m| replies << [t, m] }
end
sleep 0.3

req_id = "smoke#{Time.now.to_i}"
MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'smoke-pub') do |c|
  c.publish('runes/prompts', JSON.generate('request_id' => req_id,
                                           'prompt' => 'write smoke.txt then read it back'))
end

reply = nil
Timeout.timeout(15) do
  loop do
    topic, msg = replies.pop
    next unless topic == "runes/prompts/#{req_id}/response"
    reply = msg
    break
  end
end

puts '--- reply ---'
puts reply
artifact = File.join(ws, 'smoke.txt')
checks = [
  [!reply.nil?, 'correlated reply received'],
  [reply.include?('Wrote'), 'write_file step executed'],
  [reply.include?('smoke ok'), 'read_file step returned content'],
  [File.file?(artifact), 'artifact written in workspace'],
  [File.file?(File.join(settings.root, 'log', 'journal.jsonl')), 'journal recorded']
]
checks.each { |ok, label| puts "#{ok ? 'PASS' : 'FAIL'}: #{label}" }
passed = checks.all? { |ok, _ok_label| ok }
puts passed ? 'ALL CHECKS PASSED' : 'SMOKE FAILED'
exit(passed ? 0 : 1)
rescue Timeout::Error
  puts 'SMOKE FAILED: no reply within 15s'
  exit 1
ensure
  dt&.kill
  rt&.kill
  bt&.kill
  FileUtils.remove_entry(ws) if ws.to_s.start_with?(Dir.tmpdir) && Dir.exist?(ws)
end
