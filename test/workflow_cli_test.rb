# frozen_string_literal: true

require_relative "test_helper"

require "json"
require "open3"
require "timeout"

# Why the binstub is tested out of process: `bin/runes-workflow` is what a
# user actually runs (see README Quick Start), and the interesting failure
# modes — exit codes, what lands on stdout vs stderr, argument splitting —
# only exist at the process boundary. The workflows used here are ruby/cmd
# only, so nothing here can reach a provider.
#
# `RUNES_ROOT` is pointed at a throwaway tree (test_helper already did this
# for the in-process suite) so the CLI cannot read the developer's config.
class WorkflowCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "runes-workflow")

  def setup
    @dir = Dir.mktmpdir("runes-cli-")
    @env = { "RUNES_ROOT" => @dir }
    %w[DEEPSEEK DEEPSEEK_API_KEY SYNTHETIC SYNTHETIC_API_KEY CEREBRAS CEREBRAS_API_KEY
       OPENAI_API_KEY ANTHROPIC_API_KEY].each { |key| @env[key] = nil }
  end

  def teardown
    FileUtils.remove_entry(@dir) if Dir.exist?(@dir) && @dir.start_with?(Dir.tmpdir)
  end

  def test_help_and_version
    status, out, err = run_cli("help")
    assert_equal 0, status
    assert_includes out, "runes-workflow execute FILE"
    assert_empty err.strip

    status, out, _err = run_cli("version")
    assert_equal 0, status
    assert_equal "runes-workflow #{Runes::VERSION}", out.strip
  end

  def test_no_arguments_prints_usage_without_failing
    status, out, _err = run_cli
    assert_equal 0, status
    assert_includes out, "Usage:"
  end

  def test_missing_file_fails_with_a_message
    status, _out, err = run_cli("execute", "does-not-exist.rb")

    assert_equal 1, status
    assert_includes err, "does-not-exist.rb"
  end

  def test_no_file_argument_exits_2
    status, _out, err = run_cli("execute")

    assert_equal 2, status
    assert_includes err, "no workflow file given"
  end

  def test_runs_a_workflow_and_prints_the_final_output
    workflow = write_workflow(<<~RUBY)
      execute do
        cmd(:greet) { "echo hello-world" }
        ruby(:check) { { out: cmd!(:greet).out, ok: cmd!(:greet).status.success? } }
      end
    RUBY

    status, out, err = run_cli("execute", workflow)

    assert_equal 0, status, "cli failed: #{err}"
    assert_includes out, 'out: "hello-world\n"'
    assert_includes out, "ok: true"
  end

  # An `outputs { ... }` block returns a plain value, not a rune output; the
  # runner must still print it (it printed nothing until this was fixed).
  def test_prints_a_plain_outputs_value
    workflow = write_workflow(<<~RUBY)
      execute do
        ruby(:value) { 21 }
        outputs { |_value, _index| { doubled: ruby!(:value).value * 2 } }
      end
    RUBY

    status, out, err = run_cli("execute", workflow)

    assert_equal 0, status, "cli failed: #{err}"
    assert_includes out, "{doubled: 42}"
  end

  def test_quiet_prints_nothing_on_success
    workflow = write_workflow("execute do\n  ruby(:value) { 42 }\nend\n")

    status, out, err = run_cli("--quiet", "execute", workflow)

    assert_equal 0, status, "cli failed: #{err}"
    assert_empty out
  end

  def test_a_failing_rune_exits_non_zero_and_reports_on_stderr
    workflow = write_workflow(<<~RUBY)
      execute do
        cmd(:boom) { ["ruby", "-e", "warn 'nope'; exit 3"] }
      end
    RUBY

    status, out, err = run_cli("execute", workflow)

    assert_equal 1, status
    assert_empty out
    assert_match(/FailCog|status code 3/, err)
  end

  def test_a_target_reaches_the_workflow_as_a_param
    # The old test only asserted top-level output, so it passed with no
    # target at all. A target is a workflow *param* (Roast semantics), so
    # assert it actually arrives (W5-12).
    workflow = write_workflow(<<~RUBY)
      execute do
        ruby(:echo) { |_my, _scope_value, _scope_index| "target=\#{target!}" }
      end
    RUBY

    status, out, err = run_cli("execute", workflow, "double")

    assert_equal 0, status, "cli failed: #{err}"
    assert_includes out, "target=double"
  end

  def test_a_hostile_workflow_kwarg_cannot_inject_a_shell_command
    # The doc5.md W5-1 reproduction, out of process: the interpolated kwarg
    # must not be able to create a file.
    marker = File.join(@dir, "pwned")
    workflow = write_workflow(<<~RUBY)
      execute do
        cmd(:leak) { "echo " + kwarg(:name).to_s }
      end
    RUBY

    status, _out, err = run_cli("execute", workflow, "--", "name=hello; echo INJECTED > #{marker}")

    assert_equal 1, status
    assert_includes err, "ShellSyntaxError"
    refute File.exist?(marker), "the hostile kwarg must not create a file"
  end

  def test_workflow_args_after_the_separator_are_not_cli_options
    workflow = write_workflow(<<~RUBY)
      execute do
        ruby(:value) { "--quiet is workflow data here" }
      end
    RUBY

    status, out, err = run_cli("execute", workflow, "--", "--quiet")

    assert_equal 0, status, "cli failed: #{err}"
    assert_includes out, "--quiet is workflow data here"
  end

  # --- in-process: argument parsing ------------------------------------

  def test_parse_workflow_args_splits_kwargs_and_flags
    targets, flags, kwargs = cli_module.parse_workflow_args(%w[a b -- verbose env=staging --loud])

    assert_equal %w[a b], targets
    assert_equal %i[verbose loud], flags
    assert_equal({ env: "staging" }, kwargs)
  end

  def test_extract_cli_options_only_touches_the_head
    head, print_output = cli_module.extract_cli_options(%w[execute w.rb -q])
    assert_equal %w[execute w.rb], head
    refute print_output

    head, print_output = cli_module.extract_cli_options(%w[execute w.rb -- --quiet])
    assert_equal %w[execute w.rb -- --quiet], head
    assert print_output, "flags after `--` belong to the workflow"
  end

  # E5-6: the policy is wired to the real entry point, not just the seam.
  # Without this, `RUNES_WORKFLOW_POLICY` could be documented and inert.
  def test_the_cli_refuses_a_command_the_policy_denies
    policy_path = File.join(@dir, "policy.json")
    File.write(policy_path, JSON.generate("tools" => {}))
    workflow = write_workflow(%(execute { cmd(:x) { "echo should-not-run" } }))
    @env["RUNES_WORKFLOW_POLICY"] = policy_path

    status, out, err = run_cli("execute", workflow)

    assert_equal 1, status, "a refused rune must fail the process"
    assert_includes err, "policy"
    assert_includes err, "cmd"
    refute_includes out, "should-not-run", "the command must not have executed"
  end

  def test_the_cli_runs_normally_when_no_policy_is_configured
    workflow = write_workflow(%(execute { cmd(:x) { "echo fine" } }))

    status, _out, err = run_cli("execute", workflow)

    assert_equal 0, status, "unguarded is still the default: #{err}"
  end

  private

  # The binstub is not a `.rb` file, so `require` cannot find it; `load` can,
  # and its `$PROGRAM_NAME` guard keeps it from exiting the test process.
  # Loaded once per class: re-loading would re-initialise its constants.
  def self.cli_module
    @cli_module ||= begin
      load BIN
      RunesWorkflowCli
    end
  end

  def cli_module
    self.class.cli_module
  end

  def write_workflow(source)
    path = File.join(@dir, "workflow_#{SecureRandom.hex(4)}.rb")
    File.write(path, source)
    path
  end

  def run_cli(*args)
    Open3.capture3(@env, RbConfig.ruby, BIN, *args, chdir: @dir)
      .then { |out, err, status| [status.exitstatus, out, err] }
  end
end
