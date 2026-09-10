# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/runes/workflow"

# --- fakes -------------------------------------------------------------
# Every external edge (the cmd process, the agent CLI/provider, the chat
# backend) is faked, so this test proves the engine end to end with no
# network and no real subprocess.

class FakeCommandStatus
  def initialize(success, exitstatus)
    @success = success
    @exitstatus = exitstatus
  end

  def success? = @success
  attr_reader :exitstatus
end

class FakeCmdRunner
  attr_reader :commands

  def initialize(out, err: "", success: true, exitstatus: 0)
    @out = out
    @err = err
    @success = success
    @exitstatus = exitstatus
    @commands = []
  end

  def execute(command, args: [], stdin: nil, **options)
    @commands << ([command] + args)
    Runes::CommandRunner::Result.new(
      out: @out,
      err: @err,
      status: FakeCommandStatus.new(@success, @exitstatus)
    )
  end
end

class FakeAgentProvider
  attr_reader :prompts

  def initialize(response)
    @response = response
    @prompts = []
  end

  def invoke(input)
    @prompts << input.prompts.dup
    Runes::Plugins::Agent::Output.new(
      response: @response,
      session: "fake-session-1",
      stats: Runes::Plugins::Agent::Stats.new
    )
  end
end

# A command-runner double that replays canned stdout lines and records argv.
class CapturingRunner
  attr_reader :calls

  def initialize(lines, success: true, err: "")
    @lines = lines
    @success = success
    @err = err
    @calls = []
  end

  def execute(command, args: [], stdin: nil, **options)
    @calls << { command: command, args: args, stdin: stdin, options: options }
    handler = options[:stdout_handler]
    @lines.each { |line| handler&.call("#{line}\n") }
    Runes::CommandRunner::Result.new(
      out: @lines.map { |line| "#{line}\n" }.join,
      err: @err,
      status: FakeCommandStatus.new(@success, @success ? 0 : 1)
    )
  end
end

class FakeChatBackend
  DEFAULT_RESPONSE = "Here is the summary:\nStakeholders: the review found no critical issues."

  attr_reader :prompts

  def initialize(response = nil)
    @response = response || DEFAULT_RESPONSE
    @prompts = []
  end

  def chat(prompt:, session:, config:)
    @prompts << prompt
    Runes::Plugins::Chat::Reply.new(
      response: @response,
      messages: [{ role: "user", content: prompt }, { role: "assistant", content: @response }],
      model: "fake-model",
      input_tokens: 3,
      output_tokens: 7
    )
  end
end

# Records the resolved config a chat backend is handed (W5-3). It also calls
# the validators, so a test can prove they see the configured values.
class RecordingChatBackend
  attr_reader :calls

  def initialize
    @calls = []
  end

  def chat(prompt:, session:, config:)
    @calls << {
      prompt: prompt,
      provider: config.valid_provider!,
      model: config.valid_model,
      temperature: config.valid_temperature,
      api_key: config.valid_api_key!,
      base_url: config.valid_base_url
    }
    Runes::Plugins::Chat::Reply.new(response: "fake", messages: [], model: "fake")
  end
end

# A duck-typed Net::HTTP response for the injectable LLM transport.
class RecordingChatResponse
  attr_reader :code, :body

  def initialize(code, body)
    @code = code
    @body = body
  end

  def success? = @code == "200"
  def [](_key) = nil
end

class RecordingChatTransport
  attr_reader :calls

  def initialize(body)
    @body = body
    @calls = []
  end

  def post(uri:, route:, body:, timeout_s:)
    @calls << { uri: uri.to_s, route: route, body: JSON.parse(body) }
    RecordingChatResponse.new("200", @body)
  end
end

class RoastCompatibilityTest < Minitest::Test
  # The Roast README example, verbatim — read from the shipped example file so
  # the artifact users run is the artifact this suite proves.
  README_EXAMPLE = File.read(File.expand_path("../examples/analyze_codebase.rb", __dir__))

  CHANGED_FILES = "app/models/user.rb\napp/controllers/users_controller.rb\n"
  AGENT_RESPONSE = "Review complete: no critical issues found."

  def setup
    Runes::Workflow.register_builtin_runes!
    @env = {}
    %w[ROAST_DEFAULT_CHAT_PROVIDER ROAST_DEFAULT_AGENT_PROVIDER RUNES_LLM_ADAPTER].each do |key|
      @env[key] = ENV[key]
      ENV.delete(key)
    end
    @dirs = []
    @cmd_runner = FakeCmdRunner.new(CHANGED_FILES)
    @agent_provider = FakeAgentProvider.new(AGENT_RESPONSE)
    @chat_backend = FakeChatBackend.new

    Runes::Plugins::Cmd.command_runner = @cmd_runner
    Runes::Plugins::Agent.provider_factory = ->(_config) { @agent_provider }
    Runes::Plugins::Chat.backend = @chat_backend
  end

  def teardown
    Runes::Plugins::Cmd.reset_command_runner!
    Runes::Plugins::Agent.reset_seams!
    Runes::Plugins::Chat.reset_backend!
    @env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    @dirs.each { |dir| FileUtils.remove_entry(dir) if Dir.exist?(dir) }
  end

  def test_all_seven_runes_are_registered_as_rune_plugins
    %i[agent call chat cmd map repeat ruby].each do |name|
      assert_includes Runes::Plugin.names(kind: :rune), name
      assert Runes::Plugin.fetch(name).klass < Runes::Rune
    end
  end

  def test_roast_readme_example_runs_end_to_end
    workflow = nil
    capture_io do
      workflow = Runes::Workflow.from_file(write_workflow(README_EXAMPLE), Runes::WorkflowParams.new)
    end

    # 1. The cmd rune ran, unmodified, with no shell string.
    assert_equal 1, @cmd_runner.commands.length, "cmd should have run once"
    assert_equal "git diff --name-only HEAD~5..HEAD", @cmd_runner.commands.first.join(" ")

    # 2. `cmd!(:recent_changes).lines` was available inside the agent block and
    #    its lines were interpolated into the prompt.
    assert_equal 1, @agent_provider.prompts.length, "agent should have run once"
    agent_prompt = @agent_provider.prompts.first.first
    assert_includes agent_prompt, "Review these recently changed files for potential issues:"
    assert_includes agent_prompt, "app/models/user.rb"
    assert_includes agent_prompt, "app/controllers/users_controller.rb"
    assert_includes agent_prompt, "Focus on security, performance, and maintainability."

    # 3. `agent!(:review).response` was fed into the chat prompt.
    assert_equal 1, @chat_backend.prompts.length, "chat should have run once"
    assert_includes @chat_backend.prompts.first, AGENT_RESPONSE

    # 4. `chat!(:summary).response` is readable from the final output.
    output = workflow.final_output
    assert_kind_of Runes::Plugins::Chat::Output, output
    assert_equal FakeChatBackend::DEFAULT_RESPONSE, output.response
    assert_includes output.lines, "Stakeholders: the review found no critical issues."
    assert_equal FakeChatBackend::DEFAULT_RESPONSE, output.session.messages.last[:content]
    assert_includes output.session.messages.first[:content], AGENT_RESPONSE
    assert workflow.completed?
  end

  def test_no_network_is_touched
    # The fakes are the only external edges; if any real client were used, the
    # cmd/agent/chat fakes would not have been called (or the run would have
    # raised for a missing API key / CLI).
    capture_io do
      Runes::Workflow.from_file(write_workflow(README_EXAMPLE), Runes::WorkflowParams.new)
    end

    assert_equal 1, @cmd_runner.commands.length
    assert_equal 1, @agent_provider.prompts.length
    assert_equal 1, @chat_backend.prompts.length
  end

  def test_named_scope_workflow_runs_through_call_map_and_repeat
    source = <<~RUBY
      execute(:double) do
        ruby(:value) { |_my, scope_value, _scope_index| scope_value * 2 }
      end

      execute(:increment) do
        ruby(:value) { |_my, scope_value, _scope_index| scope_value + 1 }
      end

      execute do
        call(:called, run: :double) { 21 }
        map(:mapped, run: :double) { |my| my.items = [1, 2, 3] }
        repeat(:repeated, run: :increment) { |my| my.value = 0; my.max_iterations = 3 }
        outputs do |_scope_value, _scope_index|
          {
            called: from(call!(:called)),
            mapped: collect(map!(:mapped)),
            reduced: reduce(map!(:mapped), 0) { |acc, output, _item, _index| acc + output.value },
            repeated: repeat!(:repeated).value,
            results: collect(repeat!(:repeated).results)
          }
        end
      end
    RUBY

    workflow = nil
    capture_io do
      workflow = Runes::Workflow.from_file(write_workflow(source), Runes::WorkflowParams.new)
    end

    final = workflow.final_output
    assert_equal 42, final[:called].value
    assert_equal [2, 4, 6], final[:mapped].map(&:value)
    assert_equal 12, final[:reduced]
    assert_equal 3, final[:repeated].value
    assert_equal [1, 2, 3], final[:results].map(&:value)
  end

  # --- cmd ------------------------------------------------------------

  def test_cmd_rune_honours_fail_on_error_and_array_coercion
    failing = FakeCmdRunner.new("", err: "boom", success: false, exitstatus: 3)
    Runes::Plugins::Cmd.command_runner = failing

    assert_raises(Runes::ControlFlow::FailCog) do
      run_source('execute { cmd(:x) { "false" } }')
    end

    output = run_source(<<~RUBY)
      config { cmd { no_fail_on_error! } }
      execute do
        cmd(:x) { ["git", "diff"] }
        outputs { |_value, _index| [cmd!(:x).out, cmd!(:x).err, cmd!(:x).status.success?] }
      end
    RUBY

    assert_equal ["", "boom", false], output
    assert_equal %w[git diff], failing.commands.last
  end

  def test_cmd_rejects_a_hash_input_with_an_actionable_message
    # A Hash is not part of Roast's cmd surface. Roast would fail with the
    # generic "'command' is required"; say what the block actually returned.
    error = assert_raises(Runes::Cog::Input::InvalidInputError) do
      run_source('execute { cmd(:x) { { command: "echo", args: ["hi"] } } }')
    end

    assert_includes error.message, "argv Array, not a Hash"
    assert_includes error.message, ":command"
    assert_empty @cmd_runner.commands, "nothing should have been executed"
  end

  # --- W5-9: the rune's working directory must reach the child -----------

  def test_agent_working_directory_is_passed_to_the_runner
    dir = File.join(@dirs.first || Dir.mktmpdir("runes-wd-"), "sub")
    FileUtils.mkdir_p(dir)
    @dirs << dir unless @dirs.include?(dir)
    runner = CapturingRunner.new([JSON.generate("type" => "assistant", "message" => "ok")])
    Runes::Plugins::Agent.command_runner = runner
    Runes::Plugins::Agent.provider_factory = nil

    run_source(<<~RUBY)
      config do
        agent(:a) do
          provider(:pi)
          working_directory("#{dir}")
        end
      end
      execute { agent(:a) { "hi" } }
    RUBY

    call = runner.calls.last
    refute_nil call, "the runner must have been invoked"
    assert_equal dir, call[:options][:working_directory].to_s,
                 "Roast honours working_directory; the rune used to accept and ignore it (W5-9)"
  end

  # --- chat config ----------------------------------------------------

  def test_chat_config_surface
    config = Runes::Plugins::Chat::Config.new

    assert_equal :openai, config.valid_provider!
    assert_equal "gpt-4o-mini", config.valid_model
    assert_equal "https://api.openai.com/v1", config.valid_base_url
    refute config.show_prompt?
    assert config.show_response?
    assert config.show_stats?
    refute config.verify_model_exists?
    assert_nil config.valid_temperature

    config.provider(:anthropic)
    assert_equal :anthropic, config.valid_provider!
    assert_equal "claude-haiku-4-5", config.valid_model
    assert_equal "https://api.anthropic.com", config.valid_base_url

    config.provider(:nope)
    assert_raises(Runes::Cog::Config::InvalidConfigError) { config.valid_provider! }

    config.use_default_provider!
    config.model("my-model")
    assert_equal "my-model", config.valid_model
    config.use_default_model!
    assert_equal "gpt-4o-mini", config.valid_model

    config.temperature(0.5)
    assert_in_delta 0.5, config.valid_temperature
    assert_raises(ArgumentError) { config.temperature(1.5) }
    config.use_default_temperature!
    assert_nil config.valid_temperature

    config.quiet!
    refute config.display?

    providers = Runes::Plugins::Chat::Config::PROVIDERS
    assert_equal %i[openai anthropic perplexity gemini], providers.keys
    assert_equal "OPENAI_API_KEY", providers.dig(:openai, :api_key_env_var)
    assert_equal "https://generativelanguage.googleapis.com/v1beta", providers.dig(:gemini, :default_base_url)
    assert_equal "sonar", providers.dig(:perplexity, :default_model)
    assert_nil providers.dig(:perplexity, :base_url_env_var)
  end

  def test_chat_passes_its_resolved_config_to_the_backend
    backend = RecordingChatBackend.new
    Runes::Plugins::Chat.backend = backend

    output = run_source(<<~RUBY)
      config do
        chat(:q) do
          provider(:anthropic)
          model("claude-haiku-4-5")
          temperature(0.25)
          api_key("explicit-key")
          base_url("https://example.test/v1")
          no_show_stats!
          no_show_response!
        end
      end
      execute do
        chat(:q) { "hi" }
        outputs { |_value, _index| chat!(:q).response }
      end
    RUBY

    assert_equal "fake", output
    call = backend.calls.first
    assert_equal :anthropic, call[:provider]
    assert_equal "claude-haiku-4-5", call[:model]
    assert_in_delta 0.25, call[:temperature]
    assert_equal "explicit-key", call[:api_key]
    assert_equal "https://example.test/v1", call[:base_url]
  end

  def test_chat_validates_the_provider_before_any_request
    backend = RecordingChatBackend.new
    Runes::Plugins::Chat.backend = backend

    assert_raises(Runes::Cog::Config::InvalidConfigError) do
      run_source(<<~RUBY)
        config { chat(:q) { provider(:bogus_provider); api_key("k") } }
        execute { chat(:q) { "hi" } }
      RUBY
    end

    assert_empty backend.calls, "an invalid provider must raise before any prompt is sent (W5-3)"
  end

  def test_chat_router_client_threads_the_config_into_the_http_request
    require_relative "../lib/runes/core/settings"
    body = JSON.generate(choices: [{ message: { role: "assistant", content: "ok" } }])
    transport = RecordingChatTransport.new(body)
    client = Runes::Plugins::Chat::RouterClient.new(Runes::Core::Settings.new, transport: transport)

    result = client.chat([{ role: "user", content: "hi" }], json: false,
                        provider: :openai, model: "gpt-4o-mini", temperature: 0.25,
                        api_key: "k-123", base_url: "https://api.openai.com/v1")

    assert_equal "ok", result[:content]
    call = transport.calls.first
    assert_equal "https://api.openai.com/v1/chat/completions", call[:uri]
    assert_equal "openai", call[:route].provider
    assert_equal "k-123", call[:route].api_key
    assert_equal "gpt-4o-mini", call[:route].model
    assert_in_delta 0.25, call[:route].sampling_params[:temperature]
    assert_equal "gpt-4o-mini", call[:body]["model"]
    assert_in_delta 0.25, call[:body]["temperature"]
  end

  def test_chat_maps_a_length_truncated_result_to_max_tokens_exceeded
    backend_class = Class.new(Runes::Plugins::Chat::BaseBackend) do
      private

      def dispatch(_messages, _config)
        { ok: false, error: "deepseek response was truncated (finish_reason=length) — raise max_tokens" }
      end
    end

    error = assert_raises(Runes::Plugins::Chat::MaxTokensExceededError) do
      backend_class.new.chat(prompt: "hi", session: nil, config: Runes::Plugins::Chat::Config.new)
    end

    assert_includes error.message, "finish_reason=length"
  end

  # --- agent providers ------------------------------------------------

  def test_agent_pi_provider_builds_exact_argv_and_parses_events
    lines = [
      JSON.generate(type: "session", id: "pi-session"),
      JSON.generate(type: "turn_start"),
      JSON.generate(
        type: "message_end",
        message: {
          role: "assistant",
          model: "pi-model",
          content: [{ type: "text", text: "pi answer" }],
          usage: { input: 10, output: 5, cost: { total: 0.02 } }
        }
      )
    ]
    runner = CapturingRunner.new(lines)
    Runes::Plugins::Agent.command_runner = runner
    Runes::Plugins::Agent.provider_factory = nil

    result = run_source(<<~RUBY)
      config do
        agent(:a) do
          provider(:pi)
          model("anthropic/claude-sonnet")
          replace_system_prompt("SYS")
          append_system_prompt("MORE")
          no_show_stats!
          no_show_response!
        end
      end
      execute do
        agent(:a) { "do the thing" }
        outputs do |_value, _index|
          [agent!(:a).response, agent!(:a).session, agent!(:a).stats.num_turns,
           agent!(:a).stats.usage.input_tokens, agent!(:a).stats.usage.cost_usd]
        end
      end
    RUBY

    call = runner.calls.first
    assert_equal ["pi", "--mode", "json", "-p", "--model", "anthropic/claude-sonnet",
                  "--system-prompt", "SYS", "--append-system-prompt", "MORE", "--no-session"],
                 call[:command]
    assert_equal "do the thing", call[:stdin]
    assert_equal ["pi answer", "pi-session", 1, 10], result[0..3]
    assert_in_delta 0.02, result[4]
  end

  def test_agent_claude_provider_builds_exact_argv_and_parses_result
    lines = [
      JSON.generate(type: "system", subtype: "init", session_id: "claude-session"),
      JSON.generate(type: "assistant", message: {
        role: "assistant", content: [{ type: "text", text: "partial" }]
      }),
      JSON.generate(
        type: "result", subtype: "success", result: "claude answer",
        session_id: "claude-session", num_turns: 2, total_cost_usd: 0.03,
        usage: { input_tokens: 7, output_tokens: 4 }
      )
    ]
    runner = CapturingRunner.new(lines)
    Runes::Plugins::Agent.command_runner = runner
    Runes::Plugins::Agent.provider_factory = nil

    result = run_source(<<~RUBY)
      config do
        agent(:a) do
          provider(:claude)
          model("anthropic/claude-haiku")
          no_apply_permissions!
          no_show_stats!
          no_show_response!
        end
      end
      execute do
        agent(:a) { "review" }
        outputs do |_value, _index|
          [agent!(:a).response, agent!(:a).session, agent!(:a).stats.num_turns,
           agent!(:a).stats.usage.input_tokens]
        end
      end
    RUBY

    assert_equal ["claude", "-p", "--verbose", "--output-format", "stream-json",
                  "--model", "claude-haiku", "--dangerously-skip-permissions"],
                 runner.calls.first[:command]
    assert_equal ["claude answer", "claude-session", 2, 7], result
  end

  def test_agent_non_zero_status_appends_stderr
    runner = CapturingRunner.new([], success: false, err: "cli exploded")
    Runes::Plugins::Agent.command_runner = runner
    Runes::Plugins::Agent.provider_factory = nil

    result = run_source(<<~RUBY)
      config { agent(:a) { no_show_stats!; no_show_response! } }
      execute do
        agent(:a) { "go" }
        outputs { |_value, _index| agent!(:a).response }
      end
    RUBY

    assert_includes result, "cli exploded"
  end

  def test_agent_timeout_reaches_the_command_runner
    runner = CapturingRunner.new([])
    Runes::Plugins::Agent.command_runner = runner
    Runes::Plugins::Agent.provider_factory = nil

    run_source(<<~RUBY)
      config { agent(:a) { timeout(0.5); no_show_stats!; no_show_response! } }
      execute { agent(:a) { "go" } }
    RUBY

    assert_in_delta 0.5, runner.calls.first[:options][:timeout], 0.0001
  end

  def test_agent_config_surface
    config = Runes::Plugins::Agent::Config.new

    assert_equal :pi, config.valid_provider!
    assert config.apply_permissions?
    refute config.show_prompt?
    assert config.show_progress?
    assert config.show_response?
    assert config.show_stats?
    assert_nil config.valid_command
    assert_nil config.valid_model

    config.provider(:claude)
    assert_equal :claude, config.valid_provider!
    config.provider(:unknown)
    assert_raises(Runes::Cog::Config::InvalidConfigError) { config.valid_provider! }

    config.command("pi --foo")
    assert_equal "pi --foo", config.valid_command
    config.use_default_command!
    assert_nil config.valid_command

    config.no_apply_permissions!
    refute config.apply_permissions?
    config.apply_permissions!
    assert config.apply_permissions?

    config.quiet!
    refute config.display?
  end

  # --- system-rune error paths ---------------------------------------

  def test_system_rune_requires_a_run_scope
    %w[call map repeat].each do |verb|
      assert_raises(Runes::ExecutionManager::ExecutionScopeNotSpecifiedError) do
        run_source("execute { #{verb}(:x) { 1 } }")
      end
    end
  end

  def test_unknown_call_scope_raises
    assert_raises(Runes::ExecutionManager::ExecutionScopeDoesNotExistError) do
      run_source("execute { call(:c, run: :missing) { 1 } }")
    end
  end

  def test_map_iteration_that_did_not_run_raises
    assert_raises(Runes::Plugins::Map::MapIterationDidNotRunError) do
      run_source(<<~RUBY)
        execute(:stop_at_one) do
          ruby(:value) { |_my, scope_value, _scope_index| break! if scope_value >= 1; scope_value }
        end
        execute do
          map(:m, run: :stop_at_one) { |my| my.items = [0, 1, 2] }
          outputs { |_value, _index| map!(:m).iteration(2) }
        end
      RUBY
    end
  end

  private

  def run_source(source, params = Runes::WorkflowParams.new)
    workflow = nil
    capture_io { workflow = Runes::Workflow.from_file(write_workflow(source), params) }
    workflow.final_output
  end

  def write_workflow(source)
    dir = Dir.mktmpdir("runes-compat-")
    @dirs << dir
    path = File.join(dir, "analyze_codebase.rb")
    File.write(path, source)
    path
  end
end
