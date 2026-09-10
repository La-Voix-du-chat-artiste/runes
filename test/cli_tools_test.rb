require 'mqtt'
require 'timeout'
require 'json'
require 'tmpdir'
require_relative 'test_helper'

# Behavioral regression tests for the CLI tools (third audit):
#   bin/runes-client   T8 agent-id sanitization, progress subscription
#   bin/runes-daemon   T9 no `async`, fatal exceptions logged + exit 1
#   bin/runes-replay   T6 fresh request ids + replayed_from, T7 -n>=0,
#                      tail read over a large journal
class TestCliTools < Minitest::Test
  def setup
    @port = find_free_port
    @broker = Runes::MQTT::Broker.new('127.0.0.1', @port)
    @broker_thread = Thread.new { @broker.run }
    wait_for_port(@port)
    @tmp = Dir.mktmpdir('runes-cli')
  end

  def teardown
    @broker_thread&.kill
    if @tmp.to_s.start_with?(Dir.tmpdir) && Dir.exist?(@tmp)
      FileUtils.remove_entry(@tmp)
    end
  end

  def root_dir
    File.expand_path('..', __dir__)
  end

  def popen_script(script, args: [], env: {}, stdin_data: nil, timeout: 30)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(
      { 'RUNES_MQTT_HOST' => '127.0.0.1', 'RUNES_MQTT_PORT' => @port.to_s }.merge(env),
      RbConfig.ruby, script, *args,
      out: out_w, err: err_w, pgroup: true
    )
    out_w.close
    err_w.close

    out = err = ''
    readers = [Thread.new { out = out_r.read }, Thread.new { err = err_r.read }]
    status = nil
    begin
      Timeout.timeout(timeout) { Process.wait(pid) }
      status = $?
    rescue Timeout::Error
      kill_process_group(pid)
    ensure
      # Join the readers BEFORE closing the pipes. The old code closed an IO
      # from the main thread while its reader was still blocked in #read,
      # which raised IOError inside the reader and Thread#join re-raised it
      # as a bogus test error (B4-1 / E4-10). The process group is killed on
      # timeout so grandchildren cannot hold the write end open.
      readers.each { |t| t.join(5) }
      readers.each(&:kill) if readers.any?(&:alive?)
      [out_r, err_r].each { |io| io.close unless io.closed? rescue nil }
      kill_process_group(pid) if status.nil?
    end
    [status&.exitstatus, out, err]
  end

  def kill_process_group(pid)
    Process.kill('KILL', -pid)
  rescue StandardError
    nil
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

  # --- T8: --agent id is sanitized/validated -------------------------------

  def test_client_rejects_unsafe_agent_id
    status, _out, err = popen_script(File.join(root_dir, 'bin/runes-client'),
                                     args: ['--agent', 'peer/../evil', 'do it'])
    refute_equal 0, status
    assert_includes err, 'invalid agent id'
  end

  def test_client_rejects_wildcard_agent_id
    status, _out, err = popen_script(File.join(root_dir, 'bin/runes-client'),
                                     args: ['--agent', 'agent+id', 'do it'])
    refute_equal 0, status
    assert_includes err, 'invalid agent id'
  end

  def test_client_accepts_safe_agent_id_and_targets_tasks_topic
    topics = Queue.new
    watcher = MQTT::Client.connect(host: '127.0.0.1', port: @port, client_id: 't8-watch')
    watcher.subscribe('runes/agents/+/tasks', 'runes/agents/+/tasks/+/response')
    wt = Thread.new { watcher.get { |t, m| topics << [t, m] } }
    sleep 0.2

    # The agent never replies — the client will time out; we only need
    # the published envelope.
    status, _out, _err = popen_script(File.join(root_dir, 'bin/runes-client'),
                                      args: ['--agent', 'safe-agent_1', 'do it'],
                                      env: { 'RUNES_TIMEOUT_S' => '1' }, timeout: 15)
    topic, msg = Timeout.timeout(5) { topics.pop }
    assert_equal 'runes/agents/safe-agent_1/tasks', topic
    env = JSON.parse(msg)
    assert_equal 'do it', env['prompt']
    assert_match(/\A[A-Za-z0-9_.-]{1,64}\z/, env['from'])
  ensure
    wt&.kill
    watcher&.disconnect rescue nil
  end

  # --- progress subscription (enhancement) ---------------------------------

  def test_client_shows_progress_while_waiting
    # Stub agent: answer any broadcast prompt with progress events + a
    # reply. (The claim topic is gone — Phase 16 — so only the broadcast
    # topic is subscribed.)
    agent = MQTT::Client.connect(host: '127.0.0.1', port: @port, client_id: 't9-agent')
    agent.subscribe('runes/prompts')
    at = Thread.new do
      agent.get do |_topic, msg|
        env = JSON.parse(msg) rescue next
        rid = env['request_id']
        agent.publish("runes/prompts/#{rid}/progress",
                      JSON.generate('event' => 'prompt_received', 'request_id' => rid))
        agent.publish("runes/prompts/#{rid}/response", 'the answer')
      end
    end
    sleep 0.2

    status, out, _err = popen_script(File.join(root_dir, 'bin/runes-client'),
                                     args: ['hello agent'], timeout: 20)
    assert_equal 0, status
    assert_includes out, 'agent claimed the prompt', 'progress events must be surfaced'
    assert_includes out, 'the answer', 'the correlated reply must be printed'
  ensure
    at&.kill
    agent&.disconnect rescue nil
  end

  # --- T6: replay uses fresh request ids -----------------------------------

  def test_replay_republishes_with_fresh_request_id_and_provenance
    # Hermetic (B4-13): write the fixture journal in the test's own tmp root
    # and point the CLI at it with RUNES_ROOT. Writing to the real
    # log/journal.jsonl and deleting it in `ensure` destroyed the
    # developer's audit trail on every test run.
    journal = File.join(@tmp, 'log', 'journal.jsonl')
    original_id = "orig#{Time.now.to_i}"
    FileUtils.mkdir_p(File.dirname(journal))
    File.write(journal, "#{JSON.generate('request_id' => original_id, 'agent' => 'a',
                                         'prompt' => 'replay me', 'status' => 'complete',
                                         'at' => Time.now.utc.iso8601)}\n")

    published = Queue.new
    watcher = MQTT::Client.connect(host: '127.0.0.1', port: @port, client_id: 't6-watch')
    watcher.subscribe('runes/prompts')
    wt = Thread.new { watcher.get { |t, m| published << [t, m] } }
    sleep 0.2

    status, _out, err = popen_script(File.join(root_dir, 'bin/runes-replay'),
                                     args: ['--replay'], timeout: 20,
                                     env: { 'RUNES_ROOT' => @tmp })
    assert_equal 0, status
    assert_includes err, 'Replay published.'

    _topic, msg = Timeout.timeout(5) { published.pop }
    env = JSON.parse(msg)
    refute_equal original_id, env['request_id'], 'replay must use a FRESH request id (T6)'
    assert_equal original_id, env['replayed_from'], 'replay must record provenance'
    assert_equal 'replay me', env['prompt']
  ensure
    wt&.kill
    watcher&.disconnect rescue nil
    File.delete(journal) if journal && File.file?(journal)
  end

  # --- T7: negative -n rejected --------------------------------------------

  def test_replay_rejects_negative_last
    status, _out, err = popen_script(File.join(root_dir, 'bin/runes-replay'),
                                     args: ['-n', '-3'])
    refute_equal 0, status
    assert_includes err, 'must be >= 0'
  end

  # --- tail read: a large journal only needs its tail ------------------------

  def test_replay_reads_only_the_tail_of_a_large_journal
    journal = File.join(@tmp, 'log', 'journal.jsonl')
    FileUtils.mkdir_p(File.dirname(journal))
    filler = JSON.generate('request_id' => 'filler', 'agent' => 'a',
                           'prompt' => 'x' * 2000, 'status' => 'complete',
                           'at' => Time.now.utc.iso8601)
    File.open(journal, 'w') do |f|
      600.times { f.puts filler } # ~1.4 MB — forces the tail path
      f.puts JSON.generate('request_id' => 'tail-entry', 'agent' => 'a',
                           'prompt' => 'the last one', 'status' => 'complete',
                           'at' => Time.now.utc.iso8601)
    end

    status, out, _err = popen_script(File.join(root_dir, 'bin/runes-replay'),
                                     args: ['-n', '1'], timeout: 20,
                                     env: { 'RUNES_ROOT' => @tmp })
    assert_equal 0, status
    assert_includes out, 'tail-entry', 'the last entry must be shown'
    refute_includes out, 'x' * 2000, 'filler entries must not be parsed/shown'
  ensure
    File.delete(journal) if journal && File.file?(journal)
  end

  # --- T9: daemon drops `async`, logs fatals, exits non-zero ----------------

  def test_daemon_fatal_exceptions_are_logged_with_backtrace_and_exit_1
    stub = File.join(@tmp, 'boom.rb')
    File.write(stub, <<~RUBY)
      require 'dispatcher_boom'
    RUBY
    # Inject a raising start via -r: prepend to Dispatcher before use.
    inj = File.join(@tmp, 'inject.rb')
    File.write(inj, <<~RUBY)
      require_relative '#{root_dir}/lib/runes/core/dispatcher'
      module Runes
        module Core
          class Dispatcher
            alias_method :__orig_start, :start
            def start
              raise RuntimeError, 'injected failure'
            end
          end
        end
      end
    RUBY

    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(
      { 'RUNES_MQTT_HOST' => '127.0.0.1', 'RUNES_MQTT_PORT' => @port.to_s },
      RbConfig.ruby, '-r', inj, File.join(root_dir, 'bin/runes-daemon'),
      out: out_w, err: err_w
    )
    out_w.close
    err_w.close
    err = ''
    poller = Thread.new { out_r.read }
    err_t = Thread.new { err = err_r.read }
    Timeout.timeout(30) { Process.wait(pid) }
    [out_r, err_r].each(&:close)
    [poller, err_t].each(&:join)

    assert_equal 1, $?.exitstatus, 'fatal daemon errors must exit non-zero'
    assert_includes err, '[Runes Daemon] FATAL RuntimeError: injected failure'
    assert_match(%r{inject\.rb:\d+:in 'Runes::Core::Dispatcher#start'}, err,
                 'backtrace must be logged')
  ensure
    Process.kill('KILL', pid) rescue nil
    Process.wait(pid) rescue nil
  end

  def test_daemon_boots_and_connects_without_async
    # The daemon never exits on its own (reactive loop) — read its
    # output until the boot markers appear, then kill it.
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(
      { 'RUNES_MQTT_HOST' => '127.0.0.1', 'RUNES_MQTT_PORT' => @port.to_s },
      RbConfig.ruby, File.join(root_dir, 'bin/runes-daemon'),
      out: out_w, err: err_w
    )
    out_w.close
    err_w.close
    captured = +''
    deadline = Time.now + 15
    ready = false
    while Time.now < deadline
      rs, = IO.select([out_r, err_r], nil, nil, 0.2)
      next unless rs
      rs.each do |io|
        captured << (io.read_nonblock(4096) rescue '')
      end
      if captured.include?('Entering reactive loop')
        ready = true
        break
      end
    end
    assert ready, "daemon never reached the reactive loop; captured:\n#{captured}"
    assert_includes captured, '[Runes Daemon] Starting'
    assert_includes captured, 'Connected to broker'
    refute captured.include?('cannot load such file -- async'),
           'the daemon must not require `async` (T9)'
  ensure
    Process.kill('KILL', pid) rescue nil
    Process.wait(pid) rescue nil
    [out_r, err_r].each(&:close) rescue nil
  end
end
