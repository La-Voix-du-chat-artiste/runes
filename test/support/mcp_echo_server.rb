#!/usr/bin/env ruby
# Tiny fixture MCP server: newline-delimited JSON-RPC 2.0 over stdio.
#
# Deliberately standalone (no project requires) so tests and the live check
# exercise the client against a server that shares no code with it — if the
# client only worked against our own Protocol helpers, nothing would be
# proven about the wire format.
#
# One tool, `echo`, with an optional `delay` argument. The delay exists so
# the client's timeout path can be tested quickly and deterministically.
require 'json'

$stdout.sync = true
$stderr.sync = true

TOOLS = [
  {
    'name' => 'echo',
    'description' => 'Echoes its message argument back.',
    'inputSchema' => {
      'type' => 'object',
      'properties' => {
        'message' => { 'type' => 'string' },
        'delay' => { 'type' => 'number', 'description' => 'Seconds to sleep before replying.' }
      },
      'required' => %w[message]
    }
  }
].freeze

def write(message)
  $stdout.write(JSON.generate(message))
  $stdout.write("\n")
  $stdout.flush
rescue Errno::EPIPE, IOError
  exit 0
end

def error(id, code, message)
  write('jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message })
end

$stderr.puts '[mcp_echo_server] ready'

while (line = $stdin.gets)
  line = line.strip
  next if line.empty?

  begin
    message = JSON.parse(line)
  rescue JSON::ParserError
    error(nil, -32_700, 'Parse error')
    next
  end
  next unless message.is_a?(Hash)

  id = message['id']
  next unless message.key?('id') # notification — never answered

  case message['method']
  when 'initialize'
    write('jsonrpc' => '2.0', 'id' => id,
          'result' => {
            'protocolVersion' => '2025-06-18',
            'capabilities' => { 'tools' => {} },
            'serverInfo' => { 'name' => 'mcp-echo-fixture', 'version' => '1.0.0' }
          })
  when 'ping'
    write('jsonrpc' => '2.0', 'id' => id, 'result' => {})
  when 'tools/list'
    write('jsonrpc' => '2.0', 'id' => id, 'result' => { 'tools' => TOOLS })
  when 'tools/call'
    params = message['params'].is_a?(Hash) ? message['params'] : {}
    name = params['name'].to_s
    args = params['arguments'].is_a?(Hash) ? params['arguments'] : {}
    if name != 'echo'
      write('jsonrpc' => '2.0', 'id' => id,
            'result' => {
              'content' => [{ 'type' => 'text', 'text' => "Error: unknown tool #{name}" }],
              'isError' => true
            })
    elsif args['hang']
      # Explicit "never answer" switch: lets the client's bounded-wait path
      # be tested without racing a real sleep. The single-threaded loop is
      # blocked, so the client must kill/close to recover.
      sleep
    else
      sleep(args['delay'].to_f) if args['delay'].to_f.positive?
      write('jsonrpc' => '2.0', 'id' => id,
            'result' => {
              'content' => [{ 'type' => 'text', 'text' => args['message'].to_s }],
              'isError' => false
            })
    end
  else
    error(id, -32_601, "Method not found: #{message['method']}")
  end
end
