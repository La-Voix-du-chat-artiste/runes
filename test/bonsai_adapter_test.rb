# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class BonsaiAdapterTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  Response = Struct.new(:code, :body)

  def test_it_builds_the_documented_non_thinking_sampler_command
    Dir.mktmpdir("bonsai-") do |dir|
      cli = File.join(dir, "bonsai_cli.py")
      model = File.join(dir, "model")
      File.write(cli, "")
      Dir.mkdir(model)
      seen = nil
      runner = lambda do |argv, stdin|
        seen = { argv: argv, stdin: stdin }
        ["answer", "", Status.new(0)]
      end

      adapter = Runes::LLM::BonsaiAdapter.new(
        mode: :command,
        model: model,
        cli: cli,
        python: "/bin/sh",
        max_tokens: 64,
        runner: runner
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
        "--temperature", "0.7",
        "--top-p", "0.8",
        "--top-k", "20",
        "--presence-penalty", "1.5"
      ], seen[:argv]
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

    adapter = Runes::LLM::BonsaiAdapter.new(
      mode: :server,
      base_url: "http://127.0.0.1:8080",
      model: "bonsai-2b",
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
    assert_equal "bonsai-2b", payload["model"]
    assert_equal 12, payload["max_tokens"]
    assert_equal 0.7, payload["temperature"]
    assert_equal 0.8, payload["top_p"]
    assert_equal 20, payload["top_k"]
    assert_equal 1.5, payload["presence_penalty"]
  end

  def test_it_cleans_the_reference_cli_output
    raw = <<~TEXT
      Prompt: 12 tokens
      ========
      La réponse.
      ========
      Generation: 8 tokens
      Peak memory: 1.2 GB
    TEXT

    assert_equal "La réponse.", Runes::LLM::BonsaiAdapter.clean_output(raw)
  end

  def test_from_env_defaults_to_the_command_adapter
    adapter = Runes::LLM::BonsaiAdapter.from_env(
      "BONSAI_MODEL" => "/tmp/model",
      "BONSAI_PYTHON" => "python3",
      "BONSAI_CLI" => "/tmp/cli.py"
    )

    assert_equal :command, adapter.mode
    assert_equal "/tmp/model", adapter.model_name
  end

  def test_it_reports_a_missing_cli_or_model_path
    Dir.mktmpdir("bonsai-") do |dir|
      cli = File.join(dir, "bonsai_cli.py")
      model = File.join(dir, "model")
      File.write(cli, "")
      Dir.mkdir(model)

      missing_cli = Runes::LLM::BonsaiAdapter.new(
        mode: :command, model: model, cli: File.join(dir, "missing.py"), python: "/bin/sh"
      )
      refute missing_cli.available?
      assert_includes missing_cli.availability_error, "CLI not found"

      missing_model = Runes::LLM::BonsaiAdapter.new(
        mode: :command, model: File.join(dir, "missing-model"), cli: cli, python: "/bin/sh"
      )
      refute missing_model.available?
      assert_includes missing_model.availability_error, "model path not found"
    end
  end

  def test_a_server_without_a_base_url_is_not_available
    adapter = Runes::LLM::BonsaiAdapter.new(mode: :server, base_url: "", model: "bonsai")

    refute adapter.available?
    assert_includes adapter.availability_error, "base_url"
  end

  def test_server_errors_are_structured
    transport = ->(**) { Response.new(503, "down") }
    adapter = Runes::LLM::BonsaiAdapter.new(
      mode: :server, base_url: "http://127.0.0.1:8080", model: "bonsai", transport: transport
    )

    result = adapter.call("prompt")

    refute result[:ok]
    assert_equal :infra, result[:status]
    assert_includes result[:error], "HTTP 503"
  end
end
