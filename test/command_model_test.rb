# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class CommandModelTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  def status(code)
    Status.new(code)
  end

  def test_it_runs_an_argv_command_without_a_shell
    seen = nil
    runner = lambda do |argv, stdin|
      seen = { argv: argv, stdin: stdin }
      ["hello\n", "", status(0)]
    end
    model = Runes::LLM::CommandModel.new(command: "echo hello", runner: runner)

    result = model.call("prompt text")

    assert result[:ok]
    assert_equal "hello", result[:content]
    assert_equal ["echo", "hello"], seen[:argv]
    assert_equal "prompt text", seen[:stdin]
    assert_equal "echo", model.model_name
  end

  def test_it_applies_a_cleaner_to_stdout
    runner = ->(_argv, _stdin) { ["\e[31manswer\e[0m\n", "", status(0)] }
    model = Runes::LLM::CommandModel.new(
      command: ["fake"],
      cleaner: ->(text) { text.gsub(/\e\[[0-9;]*m/, "").strip },
      runner: runner
    )

    result = model.call("prompt")

    assert_equal "answer", result[:content]
  end

  def test_a_non_zero_exit_is_an_infrastructure_failure
    runner = ->(_argv, _stdin) { ["", "boom\nsecond line", status(2)] }
    model = Runes::LLM::CommandModel.new(command: ["fake"], runner: runner)

    result = model.call("prompt")

    refute result[:ok]
    assert_equal :infra, result[:status]
    assert_includes result[:error], "exited 2"
    assert_includes result[:error], "boom"
  end

  def test_empty_stdout_is_an_empty_stop
    runner = ->(_argv, _stdin) { ["  \n", "warning", status(0)] }
    model = Runes::LLM::CommandModel.new(command: ["fake"], runner: runner)

    result = model.call("prompt")

    refute result[:ok]
    assert_equal :empty_stop, result[:status]
    assert_includes result[:error], "warning"
  end

  def test_a_timeout_is_an_infrastructure_failure
    runner = lambda do |_argv, _stdin|
      sleep 0.05
      ["late", "", status(0)]
    end
    model = Runes::LLM::CommandModel.new(command: ["fake"], timeout_s: 0.01, runner: runner)

    result = model.call("prompt")

    refute result[:ok]
    assert_equal :infra, result[:status]
    assert_includes result[:error], "timed out"
  end

  def test_a_missing_binary_is_an_infrastructure_failure
    runner = ->(_argv, _stdin) { raise Errno::ENOENT, "fake" }
    model = Runes::LLM::CommandModel.new(command: ["fake"], runner: runner)

    result = model.call("prompt")

    refute result[:ok]
    assert_equal :infra, result[:status]
    assert_includes result[:error], "not found"
  end

  def test_available_checks_an_absolute_path_or_path_lookup
    assert Runes::LLM::CommandModel.new(command: ["/bin/sh"]).available?
    refute Runes::LLM::CommandModel.new(command: ["/definitely/not/here"]).available?
    assert Runes::LLM::CommandModel.new(command: ["ruby"]).available?
    refute Runes::LLM::CommandModel.new(command: ["definitely-not-a-real-binary"]).available?
    refute_nil Runes::LLM::CommandModel.new(command: ["definitely-not-a-real-binary"]).availability_error
  end

  def test_an_empty_command_is_refused
    assert_raises(ArgumentError) { Runes::LLM::CommandModel.new(command: []) }
  end

  def test_it_does_not_interpolate_the_prompt_into_the_command
    seen = nil
    runner = lambda do |argv, stdin|
      seen = { argv: argv, stdin: stdin }
      ["ok", "", status(0)]
    end
    model = Runes::LLM::CommandModel.new(command: ["echo", "safe"], runner: runner)

    model.call("; rm -rf /")

    assert_equal ["echo", "safe"], seen[:argv]
    assert_equal "; rm -rf /", seen[:stdin]
  end
end
