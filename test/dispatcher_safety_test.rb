require 'tmpdir'
require_relative 'test_helper'

class TestDispatcherSafety < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-test')
    ENV['RUNES_WORKSPACE'] = @tmp
    require_relative '../lib/runes/core/settings'
    settings = Runes::Core::Settings.new
    @dispatcher = Runes::Core::Dispatcher.new(
      { host: '127.0.0.1', port: 18_883 },
      nil, nil,
      settings: settings,
      transport: RecordingTransport.new
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
    ENV.delete('RUNES_WORKSPACE')
  end

  def test_safe_path_blocks_absolute_paths
    assert_nil @dispatcher.send(:safe_path, '/etc/passwd')
  end

  def test_safe_path_blocks_dotdot_escape
    assert_nil @dispatcher.send(:safe_path, '../outside')
    assert_nil @dispatcher.send(:safe_path, 'a/../../etc/passwd')
  end

  def test_safe_path_accepts_nested_relative
    safe = @dispatcher.send(:safe_path, 'tmp/hello.rb')
    refute_nil safe
    assert safe.start_with?(File.expand_path(@tmp))
  end

  # S5-7: File.expand_path raises on a NUL byte; the tool worker used to
  # die with no reply. safe_path rejects it and the caller still answers.
  def test_null_byte_path_is_rejected_without_raising
    assert_nil @dispatcher.send(:safe_path, "a\0b")
    out = @dispatcher.send(:execute_builtin, 'write_file', { 'path' => "a\0b", 'content' => 'x' })
    assert_includes out, 'Error'
  end

  def test_tool_request_with_null_byte_path_still_replies
    ENV['RUNES_TOOL_RPC'] = '1'
    ENV['RUNES_RPC_SECRET'] = 'sec'
    published = []
    client = Object.new
    client.define_singleton_method(:publish) { |topic, payload| published << [topic, payload] }
    args = Runes::Security::RPCAuth.sign(
      'sec', 'write_file', { 'path' => "a\0b", 'content' => 'x' }
    ).merge('token' => 'sec')

    @dispatcher.handle_tool_request(client, 'write_file', JSON.generate(args))

    topic, payload = published.last
    assert_equal 'runes/tools/write_file/response', topic
    assert_includes payload, 'Error'
  ensure
    ENV.delete('RUNES_TOOL_RPC')
    ENV.delete('RUNES_RPC_SECRET')
  end

  def test_dangerous_commands_blocked
    assert @dispatcher.send(:dangerous_command?, 'rm -rf /')
    assert @dispatcher.send(:dangerous_command?, 'sudo apt install x')
    refute @dispatcher.send(:dangerous_command?, 'ls -la')
    refute @dispatcher.send(:dangerous_command?, 'mkdir -p tmp')
  end

  def test_run_command_blocks_shell_metachars
    out = @dispatcher.send(:run_in_workspace, 'ls; rm -rf /')
    assert_includes out, 'metacharacters'
  end

  def test_write_file_creates_parents
    out = @dispatcher.send(:execute_builtin, 'write_file', { 'path' => 'tmp/foo/bar.rb', 'content' => 'x' })
    assert_includes out, 'Wrote tmp/foo/bar.rb'
    assert File.file?(File.join(@tmp, 'tmp/foo/bar.rb'))
  end

  def test_summarize_formats_plan
    results = [
      { step: 1, tool: 'write_file', outcome: 'Wrote tmp/a' },
      { step: 2, tool: 'run_command', outcome: "exit=0" }
    ]
    text = @dispatcher.send(:summarize, 'do stuff', results)
    assert_includes text, 'do stuff'
    assert_includes text, 'write_file'
    assert_includes text, 'run_command'
  end

  # S-R1: child processes must not inherit provider credentials.
  def test_child_env_scrubs_api_keys
    ENV['SYNTHETIC_API_KEY'] = 'supersecret'
    ENV['MY_SERVICE_TOKEN'] = 'tok'
    env = @dispatcher.send(:scrubbed_child_env)
    refute env.key?('SYNTHETIC_API_KEY')
    refute env.key?('MY_SERVICE_TOKEN')
    assert env.key?('PATH')
  ensure
    ENV.delete('SYNTHETIC_API_KEY')
    ENV.delete('MY_SERVICE_TOKEN')
  end

  def test_run_command_child_never_sees_provider_keys
    ENV['CEREBRAS_API_KEY'] = 'leak-me'
    out = @dispatcher.send(:run_in_workspace, 'env')
    refute_includes out, 'leak-me', 'run_command children must not see provider keys (S-R1)'
  ensure
    ENV.delete('CEREBRAS_API_KEY')
  end
end
