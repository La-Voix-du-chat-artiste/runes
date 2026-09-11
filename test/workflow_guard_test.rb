# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/workflow"

# E5-6: a workflow used to be a way AROUND the capability guard — `cmd`,
# `agent` and `ruby` all execute without asking. The policy below is opt-in
# (default-deny would break every unmodified Roast file), so these tests pin
# both halves: quite inert when unset, and actually refusing when set.
class WorkflowGuardTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("runes-wfguard-")
    @policy_path = File.join(@dir, "policy.json")
    Runes::WorkflowPolicy.reset!
    @original_sink = Runes::GuardTelemetry.sink
    Runes::GuardTelemetry.sink = nil
    Runes::GuardTelemetry.reset_window!
  end

  def teardown
    Runes::WorkflowPolicy.reset!
    Runes::GuardTelemetry.sink = @original_sink
    Runes::GuardTelemetry.reset_window!
    Runes::Plugins::Cmd.reset_command_runner!
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir) && @dir.start_with?(Dir.tmpdir)
  end

  def policy(hash)
    File.write(@policy_path, JSON.generate(hash))
    @policy_path
  end

  def install(hash)
    Runes::WorkflowPolicy.guard = Runes::Capabilities::Guard.new(policy(hash))
  end

  def run_workflow(source)
    path = File.join(@dir, "workflow.rb")
    File.write(path, source)
    Runes::Workflow.from_file(path, Runes::WorkflowParams.new)
  end

  # --- off by default ------------------------------------------------------

  def test_the_policy_is_off_unless_asked_for
    refute Runes::WorkflowPolicy.enabled?
    assert_equal "off", Runes::WorkflowPolicy.describe

    run_workflow(%(execute { cmd(:x) { "echo unguarded" } })) # must not raise
    assert true
  end

  def test_install_reads_the_environment_and_can_be_reset
    assert_nil Runes::WorkflowPolicy.install(env: {})
    refute Runes::WorkflowPolicy.enabled?

    policy("tools" => { "cmd" => { "exec" => ["#"] } })
    guard = Runes::WorkflowPolicy.install(env: { "RUNES_WORKFLOW_POLICY" => @policy_path })
    refute_nil guard
    assert Runes::WorkflowPolicy.enabled?

    Runes::WorkflowPolicy.reset!
    refute Runes::WorkflowPolicy.enabled?
  end

  # --- the refusal actually prevents the work ------------------------------

  def test_a_denied_cmd_never_runs_the_process
    marker = File.join(@dir, "should-not-exist.txt")
    install("tools" => {})

    error = assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { cmd(:x) { ["ruby", "-e", "File.write('#{marker}', 'ran')"] } }))
    end

    assert_includes error.message, "cmd"
    refute File.exist?(marker), "the process must not have run at all"
  end

  def test_a_narrow_policy_allows_the_command_it_names_and_refuses_another
    install("tools" => { "cmd" => { "exec" => ["echo hello"] } })

    run_workflow(%(execute { cmd(:ok) { "echo hello" } }))
    assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { cmd(:no) { "echo goodbye" } }))
    end
  end

  def test_the_guard_covers_the_agent_rune_before_it_spawns
    calls = []
    runner = Object.new
    runner.define_singleton_method(:execute) do |*args, **kwargs|
      calls << [args, kwargs]
      Runes::CommandRunner::Result.new(out: "", err: "", status: FakeStatus.new)
    end
    Runes::Plugins::Agent.command_runner = runner
    install("tools" => {})

    assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { agent(:a) { "review this" } }))
    end
    assert_empty calls, "the agent CLI must not be spawned when the policy refuses"
  end

  def test_the_guard_covers_the_ruby_rune
    install("tools" => {})

    assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { ruby(:x) { 1 + 1 } }))
    end
  end

  # --- a policy that cannot be read fails closed ---------------------------

  def test_an_unreadable_policy_refuses_everything
    File.write(@policy_path, "{ not json")
    guard = Runes::Capabilities::Guard.new(@policy_path)
    assert guard.policy_unreadable, "the guard reports an unusable policy"
    Runes::WorkflowPolicy.guard = guard

    error = assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { cmd(:x) { "echo hi" } }))
    end
    assert_includes error.message, "could not be parsed"
    assert_equal "on (policy unreadable: fail-closed)", Runes::WorkflowPolicy.describe
  end

  def test_the_refusal_says_how_to_fix_it
    install("tools" => {})

    error = assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { cmd(:x) { "echo hi" } }))
    end

    assert_includes error.message, "RUNES_WORKFLOW_POLICY"
    assert_includes error.message, "cmd"
    assert_includes error.message, "echo hi"
  end

  # Stand-in for Process::Status; the fake runner never spawns anything.
  class FakeStatus
    def success? = true
    def exitstatus = 0
  end
  # doc5.md O2.3: a refused workflow is a refusal like any other, and it must
  # reach whatever sink the process installed.
  def test_a_refused_rune_is_reported_to_the_telemetry_sink
    seen = []
    Runes::GuardTelemetry.sink = ->(decision) { seen << decision }
    install("tools" => { "cmd" => { "exec" => ["ls"] } })

    assert_raises(Runes::WorkflowPolicy::Denied) do
      run_workflow(%(execute { cmd(:x) { "echo forbidden" } }))
    end

    assert_equal 1, seen.size
    assert_equal "workflow", seen.first["phase"]
    assert_equal "cmd", seen.first["tool"]
    assert_equal "exec", seen.first["action"]
    assert_equal "echo forbidden", seen.first["resource"]
  end

  def test_an_allowed_rune_reports_nothing
    seen = []
    Runes::GuardTelemetry.sink = ->(decision) { seen << decision }
    install("tools" => { "cmd" => { "exec" => ["echo hi"] } })

    run_workflow(%(execute { cmd(:ok) { "echo hi" } }))

    assert_empty seen
  end
end
