require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Regression tests for the fourth audit round (doc4.md):
#   B4-3 / E4-3  claim protocol: never execute inline; execution announcements
#   B4-4 / E4-4  shared string-aware JSON extraction
#   B4-5 / E4-8  mission steps use the function-calling planner
#   B4-6 / E4-7  the verifier receives real (bounded) evidence
#   B4-7 / E4-11 durable, timestamped journal rotation
#   B4-8         write_file accepts empty content
#   B4-9         VMManager honours config/.env for RUNES_WASM*
#   B4-10        byte-bounded prompt truncation
#   B4-13        Settings.default_root honours RUNES_ROOT
#   S4-1 / E4-6  tool RPC requires the shared secret (also covered in third_audit)
#   S4-2 / E4-5  run_command cannot escape the workspace
#   S4-4         the guard judges the resolved write path
class TestFourthAudit < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-a4')
    ENV['RUNES_WORKSPACE'] = File.join(@tmp, 'workspace')
    @tools = Dir.mktmpdir('runes-a4-tools')
    @settings = Runes::Core::Settings.new(root: @tmp)
  end

  def teardown
    [@tmp, @tools].each do |dir|
      FileUtils.remove_entry(dir) if dir.to_s.start_with?(Dir.tmpdir) && Dir.exist?(dir)
    end
    ENV.delete('RUNES_WORKSPACE')
    ENV.delete('RUNES_MAX_CONCURRENT')
    ENV.delete('RUNES_STARTED_GRACE_S')
    ENV.delete('RUNES_TOOL_RPC')
    ENV.delete('RUNES_RPC_SECRET')
  end

  def make_dispatcher(agent_id = 'a4-agent')
    Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 1 }, nil, nil,
      settings: @settings, agent_id: agent_id,
      tool_registry: Runes::Core::ToolRegistry.new(tools_dir: @tools),
      transport: RecordingTransport.new
    )
  end

  def recording_client
    client = Object.new
    published = Queue.new
    client.define_singleton_method(:publish) { |topic, payload| published << [topic, payload] }
    client.define_singleton_method(:published) { published }
    client
  end

  class RecordingLLM
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def call(prompt, **kwargs)
      @calls << { prompt: prompt, kwargs: kwargs }
      @response
    end

    def chat(messages, **kwargs)
      @calls << { messages: messages, kwargs: kwargs }
      @response
    end
  end

  # --- B4-3 / E4-3: no inline execution, ever -------------------------------

  def test_prompt_never_executes_on_the_reactive_loop
    ENV['RUNES_MAX_CONCURRENT'] = '1'
    d = make_dispatcher
    d.start_workers
    gate = Queue.new
    picked = Queue.new
    queue = d.instance_variable_get(:@work_queue)

    queue << -> { picked << :in; gate.pop } # occupy the only worker
    picked.pop

    ran = false
    d.dispatch_prompt { ran = true }
    sleep 0.05
    refute ran, 'dispatch_prompt must queue work, never run it inline (B4-3)'

    gate << :go
    Timeout.timeout(3) { sleep 0.01 until ran }
  ensure
    d&.instance_variable_get(:@workers)&.each { |t| t.kill }
  end

  def test_saturated_queue_is_refused_with_a_busy_reply
    ENV['RUNES_MAX_CONCURRENT'] = '1'
    d = make_dispatcher
    client = recording_client
    d.instance_variable_set(:@transport, client)
    d.start_workers

    gate = Queue.new
    picked = Queue.new
    queue = d.instance_variable_get(:@work_queue)
    queue << -> { picked << :in; gate.pop }
    picked.pop

    # Fill the remaining capacity so the next non-blocking push fails.
    d.send(:queue_capacity).times { queue << -> { gate.pop } }

    ran = false
    d.dispatch_prompt { ran = true }
    refute ran, 'a full queue must refuse, not execute inline'

    topic, payload = Timeout.timeout(3) { client.published.pop }
    assert_equal 'runes/prompts/response', topic
    assert_includes payload, 'busy'
  ensure
    gate&.push(:go)
    d&.instance_variable_get(:@workers)&.each { |t| t.kill }
  end

  # --- B4-4 / E4-4: one string-aware JSON extractor -------------------------

  def test_json_scan_is_string_aware
    json = 'Sure! {"mission_title":"use { and } in a title","todos":[{"id":1,"title":"t"}]}'
    parsed = Runes::Core::JsonScan.extract_object(json)
    assert_equal 'use { and } in a title', parsed['mission_title']

    d = make_dispatcher
    assert_equal parsed, d.send(:extract_json_object, json),
                 'the dispatcher shim must use the shared scanner'

    refute Runes::Core::JsonScan.extract_object('{"never closed": "x"')
    refute Runes::Core::JsonScan.extract_object('no json here')
    # Oversized payloads are not parsed.
    refute Runes::Core::JsonScan.extract_object('{"a":"' + ('x' * (2 * 1024 * 1024)) + '"}')
  end

  # --- B4-5 / E4-8 + B4-6 / E4-7: mission pipeline -------------------------

  def test_mission_step_uses_the_function_calling_planner_and_passes_evidence
    d = make_dispatcher
    response = {
      ok: true, mode: :tool_calls,
      tool_calls: [{ tool: 'write_file', args: { 'path' => 'todo.txt', 'content' => 'done' } }]
    }
    llm = RecordingLLM.new(response)
    d.instance_variable_set(:@llm, llm)
    todo = { 'id' => 1, 'title' => 'write a file', 'detail' => 'd', 'acceptance' => 'file exists' }
    sidecar = { 'mission_title' => 'm', 'todos' => [todo] }

    outcome = d.execute_mission_step(recording_client, 'progress', sidecar, todo)
    assert outcome[:ok]
    assert llm.calls.first[:kwargs].key?(:tools),
           'mission steps must use the same function-calling planner as build mode (B4-5)'
    assert_includes outcome[:evidence], 'Wrote todo.txt',
                    'the verifier must receive raw tool output (B4-6/E4-7)'
    assert File.file?(File.join(@tmp, 'workspace', 'todo.txt'))
  end

  def test_verifier_prompt_distinguishes_missing_from_long_evidence
    d = make_dispatcher
    todo = { 'id' => 2, 'title' => 't', 'acceptance' => 'a' }

    missing = d.send(:verify_prompt, todo, '')
    assert_includes missing, 'no execution output'

    long = d.send(:verify_prompt, todo, 'E' * 40_000)
    assert_includes long, '[evidence truncated'
    assert_operator long.bytesize, :<, 40_000
    # The old code clipped evidence at 2000 chars, which starved the verifier.
    assert_operator long.length, :>, 8_000
  end

  def test_tool_schemas_are_unique_even_with_builtin_manifests
    # tools/ ships manifests for the builtins as well; their schemas must
    # not be sent twice (DeepSeek rejects duplicates with HTTP 400).
    FileUtils.mkdir_p(File.join(@tools, 'write_file'))
    File.write(File.join(@tools, 'write_file', 'card.json'),
               JSON.generate('name' => 'write_file', 'description' => 'dup'))
    FileUtils.mkdir_p(File.join(@tools, 'echo'))
    File.write(File.join(@tools, 'echo', 'card.json'), JSON.generate('name' => 'echo'))

    d = make_dispatcher
    names = d.tool_schemas.map { |s| s.dig(:function, :name) }
    assert_equal names.uniq, names, "duplicate tool names: #{names.inspect}"
    assert_includes names, 'echo'

    # And the low-level helper dedupes too, whatever the caller passes.
    dup = [{ type: 'function', function: { name: 'read_file' } },
           { type: 'function', function: { name: 'custom' } }]
    names2 = Runes::Core::LLMClient.builtin_schemas(extra: dup).map { |s| s.dig(:function, :name) }
    assert_equal names2.uniq, names2
    assert_includes names2, 'custom'
  end

  # --- B4-8 / B4-10 ---------------------------------------------------------

  def test_write_file_accepts_empty_content
    d = make_dispatcher
    out = d.send(:execute_builtin, 'write_file', { 'path' => 'empty.txt', 'content' => '' })
    assert_includes out, 'Wrote'
    assert_equal 0, File.size(File.join(@tmp, 'workspace', 'empty.txt'))

    out = d.send(:execute_builtin, 'write_file', { 'path' => 'nope.txt' })
    assert_includes out, 'missing content'
  end

  def test_prompt_truncation_is_byte_bounded_and_valid_encoding
    d = make_dispatcher
    truncated = d.send(:truncate_prompt, 'é' * 30_000)
    assert_operator truncated.bytesize, :<=, Runes::Core::Dispatcher::MAX_PROMPT_BYTES
    assert truncated.valid_encoding?

    short = 'hello'
    assert_same short, d.send(:truncate_prompt, short)
  end

  # --- S4-2 / E4-5: run_command confinement --------------------------------

  def test_run_command_rejects_workspace_escapes
    d = make_dispatcher
    ['rm -rf ..', 'rm -rf ~', 'rm -rf ../victim', 'cat /etc/passwd',
     'cat ~/.ssh/id_rsa', 'mv ../../project /tmp'].each do |cmd|
      assert d.send(:command_path_violation?, cmd), "#{cmd.inspect} must be flagged"
      assert_includes d.send(:run_in_workspace, cmd), 'escapes the workspace'
    end
  end

  def test_run_command_allows_workspace_relative_commands
    d = make_dispatcher
    assert_nil d.send(:command_path_violation?, 'ls -la')
    assert_nil d.send(:command_path_violation?, 'mkdir -p nested/dir')
    assert_nil d.send(:command_path_violation?, 'echo hi')
    assert_includes d.send(:run_in_workspace, 'ls'), 'exit=0'
    assert_includes d.send(:run_in_workspace, 'mkdir -p nested/dir'), 'exit=0'
    assert Dir.exist?(File.join(@tmp, 'workspace', 'nested', 'dir'))
  end

  # --- S4-4: the guard judges the actual write target -----------------------

  def test_guard_is_asked_about_the_resolved_path
    d = make_dispatcher
    seen = []
    recording = Object.new
    recording.define_singleton_method(:allowed?) do |tool, action, resource|
      seen << [tool, action, resource]
      true
    end
    d.instance_variable_set(:@guard, recording)

    d.send(:execute_builtin, 'write_file', { 'path' => 'sub/../x.txt', 'content' => 'hi' })
    assert_equal ['write_file', :fs_write, 'x.txt'], seen.first,
                 'the policy must see the workspace-relative path actually written'
  end

  # --- B4-7 / E4-11: journal durability ------------------------------------

  def test_journal_rotation_uses_a_timestamped_archive
    d = make_dispatcher
    path = File.join(@tmp, 'log', 'journal.jsonl')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "line\n")
    d.send(:rotate_journal, path)

    archives = Dir.glob("#{path}.*").reject { |f| f.end_with?('.lock') }
    assert_equal 1, archives.size
    assert_match(/journal\.jsonl\.\d{8}T\d{9}/, archives.first)
    refute File.exist?("#{path}.1"), 'the shared fixed-name archive must be gone'
    refute File.exist?(path)
  end

  def test_journal_appends_under_a_lock_file
    d = make_dispatcher
    d.send(:append_journal, JSON.generate('n' => 1))
    d.send(:append_journal, JSON.generate('n' => 2))
    lines = File.readlines(File.join(@tmp, 'log', 'journal.jsonl'))
    assert_equal 2, lines.size
    assert File.exist?(File.join(@tmp, 'log', '.journal.lock'))
  end

  # --- B4-9 / B4-13 ---------------------------------------------------------

  def test_settings_default_root_honours_runes_root
    assert_equal ENV['RUNES_ROOT'], Runes::Core::Settings.default_root
    assert_equal ENV['RUNES_ROOT'], Runes::Core::Settings.new.root
    assert_equal File.join(ENV['RUNES_ROOT'], 'runes.db'),
                 File.join(Runes::Core::Settings.new.root, 'runes.db')
  end

  def test_vm_manager_reads_wasm_settings_through_the_settings_object
    settings = Object.new
    settings.define_singleton_method(:env) do |key|
      { 'RUNES_WASM_TIMEOUT_S' => '7', 'RUNES_WASM' => 'mock' }[key]
    end
    vm = Runes::WASM::VMManager.new('/nonexistent.wasm', backend: :mock, settings: settings)
    assert_equal 7.0, vm.run_timeout_s,
                 'RUNES_WASM_TIMEOUT_S from config/.env must be honoured (B4-9)'
  end
end
