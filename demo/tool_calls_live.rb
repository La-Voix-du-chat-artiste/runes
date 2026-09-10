#!/usr/bin/env ruby
# Live gate for the DEFAULT planner path (real LLM, no env flags):
# boots the embedded broker + dispatcher on default config, spies on
# LLMClient#call via a prepended module, and asserts for THIS run:
#   * schemas were sent (tools: parameter non-empty)
#   * the response mode was :tool_calls with >= 2 calls covering two
#     distinct tools (write_file + run_command)
#   * artifacts are fresh (mtime >= run start)
#   * the generated script runs green
#   * the run_command step produced output on the bus
#   * the journal entry is recorded under the client's request id
#
# Requires a provider key in config/.env (see config/.env.example).
require 'mqtt'
require 'json'
require 'timeout'
require 'tmpdir'
begin
require_relative '../lib/runes/mqtt/broker'
require_relative '../lib/runes/core/dispatcher'

port = 18_834
broker = Runes::MQTT::Broker.new('127.0.0.1', port)
bt = Thread.new { broker.run }
sleep 0.3

ws = Dir.mktmpdir('runes-toolcalls')
ENV['RUNES_WORKSPACE'] = ws
ENV.delete('RUNES_USE_TOOLS') # default config, flag UNSET
settings = Runes::Core::Settings.new
dispatcher = Runes::Core::Dispatcher.new(
  { host: '127.0.0.1', port: port }, nil, nil,
  settings: settings, agent_id: 'toolcalls-agent',
  tool_registry: Runes::Core::ToolRegistry.new(tools_dir: File.join(settings.root, 'tools'))
)

# Spy on LLMClient#call (prepended module, not a wholesale replace).
sent_schemas = nil
seen_mode = nil
seen_calls = []
spy = Module.new do
  define_method(:call) do |prompt, **kwargs|
    sent_schemas = kwargs[:tools]
    result = super(prompt, **kwargs)
    seen_mode = result[:mode]
    seen_calls.concat(Array(result[:tool_calls])) if result[:mode] == :tool_calls
    result
  end
end
dispatcher.instance_variable_get(:@llm).class.prepend(spy)

dt = Thread.new { dispatcher.start }
sleep 0.3

events = Queue.new
rt = Thread.new do
  client = MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'toolcalls-agent')
  client.subscribe('runes/prompts/+/progress', 'runes/prompts/+/response')
  client.get { |t, m| events << [t, m] }
end
sleep 0.3

req_id = "toolcalls#{Time.now.to_i}"
run_start = Time.now
MQTT::Client.connect(host: '127.0.0.1', port: port, client_id: 'toolcalls-cli') do |c|
  c.publish('runes/prompts', JSON.generate(
    'request_id' => req_id,
    'prompt' => 'Create hello.rb defining a method `greet` that returns "hello world", ' \
                'then create hello_test.rb with minitest asserting greet == "hello world", ' \
                'then run `ruby hello_test.rb` so the test executes.'
  ))
end

reply = nil
step_end = nil
Timeout.timeout(240) do
  loop do
    topic, msg = events.pop
    evt = (JSON.parse(msg) rescue {})
    if topic.end_with?('progress')
      step_end = evt if evt['event'] == 'step_end'
      next
    end
    next unless topic == "runes/prompts/#{req_id}/response"
    reply = msg
    break
  end
end

tools_used = seen_calls.map { |tc| tc[:tool] }.compact.uniq
hello = File.join(ws, 'hello.rb')
fresh = File.file?(hello) && File.mtime(hello) >= run_start
journal_has_req = File.file?(File.join(settings.root, 'log', 'journal.jsonl')) &&
                  File.read(File.join(settings.root, 'log', 'journal.jsonl')).include?(req_id)

checks = [
  [dispatcher.use_tool_calling?, 'default config uses function calling'],
  [sent_schemas.is_a?(Array) && !sent_schemas.empty?, 'schemas were sent'],
  [seen_mode == :tool_calls, "response mode was :tool_calls (got #{seen_mode.inspect})"],
  [seen_calls.size >= 2, ">= 2 tool_calls in ONE response (#{seen_calls.size})"],
  [(%w[write_file run_command] - tools_used).empty?, "two distinct tools covered (#{tools_used.inspect})"],
  [fresh, 'artifact is fresh (mtime >= run start)'],
  [reply.to_s.include?('exit=0'), 'generated script ran green'],
  [!step_end.nil?, 'run_command step produced output on the bus'],
  [journal_has_req, "journal entry recorded under #{req_id}"]
]
checks.each { |ok, label| puts "#{ok ? 'PASS' : 'FAIL'}: #{label}" }
passed = checks.all? { |ok, _| ok }
puts passed ? 'ALL CHECKS PASSED' : 'TOOL-CALLS GATE FAILED'
exit(passed ? 0 : 1)
rescue Timeout::Error => e
  puts "TOOL-CALLS GATE FAILED: #{e.message}"
  exit 1
ensure
  dt&.kill
  rt&.kill
  bt&.kill
  FileUtils.remove_entry(ws) if ws.to_s.start_with?(Dir.tmpdir) && Dir.exist?(ws)
end
