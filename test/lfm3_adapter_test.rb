# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class Lfm3AdapterTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  Response = Struct.new(:code, :body)

  def status(code = 0)
    Status.new(code)
  end

  def test_it_builds_the_documented_default_command
    Dir.mktmpdir("lfm3-") do |dir|
      cli = File.join(dir, "lfm3_cli.py")
      File.write(cli, "")
      model = "LiquidAI/LFM3-1.7B"
      seen = nil
      runner = lambda do |argv, stdin|
        seen = { argv: argv, stdin: stdin }
        ["answer", "", status]
      end

      adapter = Runes::LLM::Lfm3Adapter.new(
        mode: :command, model: model, cli: cli, python: "/bin/sh",
        max_tokens: 64, runner: runner
      )

      assert adapter.available?
      result = adapter.call("prompt")

      assert result[:ok]
      assert_equal "answer", result[:content]
      assert_equal "prompt", seen[:stdin]
      assert_equal [
        "/bin/sh", cli,
        "--model", model,
        "--max-tokens", "64",
        "--temperature", "0.1",
        "--top-k", "50",
        "--repetition-penalty", "1.1"
      ], seen[:argv]
      assert_equal "LiquidAI/LFM3-1.7B", result[:family]
      assert_equal ["text"], result[:modalities]
    end
  end

  def test_ideation_sampler_is_selected_for_the_ideator_role
    Dir.mktmpdir("lfm3-") do |dir|
      cli = File.join(dir, "lfm3_cli.py")
      File.write(cli, "")
      seen = nil
      runner = lambda do |argv, _stdin|
        seen = argv
        ["proposal", "", status]
      end

      adapter = Runes::LLM::Lfm3Adapter.new(
        mode: :command, model: "LiquidAI/LFM3-1.7B", cli: cli,
        python: "/bin/sh", runner: runner
      )
      adapter.call("prompt", role: "ideator")

      assert_includes seen, "--top-p"
      assert_equal "0.95", seen[seen.index("--top-p") + 1]
      assert_equal "0.35", seen[seen.index("--temperature") + 1]
      refute_includes seen, "--repetition-penalty"
    end
  end

  def test_math_sampler_is_explicitly_opt_in
    Dir.mktmpdir("lfm3-") do |dir|
      cli = File.join(dir, "lfm3_cli.py")
      File.write(cli, "")
      seen = nil
      runner = lambda do |argv, _stdin|
        seen = argv
        ["42", "", status]
      end

      adapter = Runes::LLM::Lfm3Adapter.new(
        mode: :command, model: "LiquidAI/LFM3-1.7B", cli: cli,
        python: "/bin/sh", runner: runner
      )
      adapter.call("prompt", math: true)

      assert_equal "1.0", seen[seen.index("--temperature") + 1]
      assert_equal "20", seen[seen.index("--top-k") + 1]
    end
  end

  def test_it_uses_the_openai_compatible_server_with_the_sampler
    captured = nil
    transport = lambda do |uri:, body:, headers:, timeout_s:|
      captured = { uri: uri, body: body, headers: headers, timeout_s: timeout_s }
      Response.new(200, Runes::Json.generate(
        "choices" => [{ "message" => { "content" => "serve answer" }, "finish_reason" => "stop" }],
        "usage" => { "prompt_tokens" => 4, "completion_tokens" => 2 }
      ))
    end

    adapter = Runes::LLM::Lfm3Adapter.new(
      mode: :server,
      base_url: "http://127.0.0.1:8080",
      model: "LiquidAI/LFM3-1.7B",
      max_tokens: 32,
      transport: transport
    )

    assert adapter.available?
    result = adapter.call("prompt", max_tokens: 12)

    assert result[:ok]
    assert_equal "serve answer", result[:content]
    assert_equal "stop", result[:finish_reason]
    assert_equal "http://127.0.0.1:8080/chat/completions", captured[:uri].to_s
    payload = Runes::Json.parse(captured[:body])
    assert_equal "LiquidAI/LFM3-1.7B", payload["model"]
    assert_equal 12, payload["max_tokens"]
    assert_equal 0.1, payload["temperature"]
    assert_equal 50, payload["top_k"]
    assert_equal 1.1, payload["repetition_penalty"]
    refute payload.key?("top_p")
  end

  def test_it_cleans_ansi_prompt_echoes_and_delimiters
    raw = <<~TEXT
      \e[31mPrompt: 12 tokens\e[0m
      ========
      La réponse.
      ========
      Generation: 8 tokens
      Peak memory: 1.2 GB
    TEXT

    assert_equal "La réponse.", Runes::LLM::Lfm3Adapter.clean_output(raw)
  end

  def test_it_unwraps_a_single_fenced_block
    assert_equal "answer", Runes::LLM::Lfm3Adapter.clean_output("```text\nanswer\n```")
  end

  def test_from_env_reads_the_documented_variables
    adapter = Runes::LLM::Lfm3Adapter.from_env(
      "LFM3_MODE" => "server",
      "LFM3_MODEL" => "custom/model",
      "LFM3_PYTHON" => "/usr/bin/python3",
      "LFM3_CLI" => "/tmp/cli.py",
      "LFM3_BASE_URL" => "http://127.0.0.1:9000",
      "LFM3_API_KEY" => "key",
      "LFM3_MAX_TOKENS" => "99"
    )

    assert_equal :server, adapter.mode
    assert_equal "custom/model", adapter.model_name
    assert_equal 99, adapter.max_tokens
  end

  def test_from_env_defaults_to_the_command_adapter_and_default_model
    adapter = Runes::LLM::Lfm3Adapter.from_env({})

    assert_equal :command, adapter.mode
    assert_equal "LiquidAI/LFM3-1.7B", adapter.model_name
    assert_equal 320, adapter.max_tokens
  end

  def test_it_reports_a_missing_cli_or_model_path
    Dir.mktmpdir("lfm3-") do |dir|
      cli = File.join(dir, "lfm3_cli.py")
      model = File.join(dir, "model")
      File.write(cli, "")
      Dir.mkdir(model)

      missing_cli = Runes::LLM::Lfm3Adapter.new(
        mode: :command, model: model, cli: File.join(dir, "missing.py"), python: "/bin/sh"
      )
      refute missing_cli.available?
      assert_includes missing_cli.availability_error, "CLI not found"

      missing_model = Runes::LLM::Lfm3Adapter.new(
        mode: :command, model: File.join(dir, "missing-model"), cli: cli, python: "/bin/sh"
      )
      refute missing_model.available?
      assert_includes missing_model.availability_error, "model path not found"
    end
  end

  def test_an_empty_command_output_is_an_empty_stop
    adapter = Runes::LLM::Lfm3Adapter.new(
      mode: :command,
      model: "LiquidAI/LFM3-1.7B",
      command: ["ruby", "-e", "exit 0"],
      runner: ->(_argv, _stdin) { ["  \n", "warning", status] }
    )

    result = adapter.call("prompt")

    refute result[:ok]
    assert_equal :empty_stop, result[:status]
  end
end
