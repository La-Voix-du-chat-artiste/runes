# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes"

class MediaAdaptersTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  def status(code = 0)
    Status.new(code)
  end

  def manifest(name)
    Runes::Swarm::Manifest.load(File.join(__dir__, "..", "config", "agents", name))
  end

  def test_vision_builds_one_media_call_and_stamps_provenance
    Dir.mktmpdir("media-") do |dir|
      image = File.join(dir, "invoice.png")
      File.binwrite(image, "PNG-DATA")
      seen = nil
      runner = lambda do |argv, stdin|
        seen = { argv: argv, stdin: stdin }
        ["page:1 total 128,40 EUR\nbox:412,88,980,140", "", status]
      end

      adapter = Runes::LLM::VisionAdapter.new(
        mode: :command,
        cli: "/tmp/media_cli.py",
        python: "/bin/sh",
        max_tokens: 128,
        runner: runner
      )

      result = adapter.call(image, manifest: manifest("vision.json"))

      assert result[:ok]
      assert_equal "LiquidAI/LFM3-VL-2B", result[:family]
      assert_equal %w[image video], result[:modalities]
      assert_equal "image", result[:artifact]["modality"]
      assert_equal Runes::SHA256.hex("PNG-DATA"), result[:artifact]["source_sha256"]
      assert_includes result[:artifact]["anchors"], "page:1"
      assert_includes result[:artifact]["anchors"], "box:412,88,980,140"
      assert_equal image, result[:artifact]["provenance"]["source"]

      assert_equal "/bin/sh", seen[:argv][0]
      assert_equal "/tmp/media_cli.py", seen[:argv][1]
      assert_equal "vision", seen[:argv][seen[:argv].index("--family") + 1]
      assert_equal "LiquidAI/LFM3-VL-2B", seen[:argv][seen[:argv].index("--model") + 1]
      assert_equal image, seen[:argv][seen[:argv].index("--input") + 1]
      assert_equal "128", seen[:argv][seen[:argv].index("--max-tokens") + 1]
      assert_includes seen[:stdin], "invoice.png"

      envelope = result[:envelope]
      assert_instance_of Runes::Swarm::Envelope, envelope
      assert_equal "perceiver.vision", envelope.identity.agent_id
      assert_equal "perception.v1", envelope.capacity.output_schema
    end
  end

  def test_audio_and_omni_pair_their_family_specific_models
    audio = Runes::LLM::AudioAdapter.new(mode: :command, cli: "/tmp/media_cli.py")
    omni = Runes::LLM::OmniAdapter.new(mode: :command, cli: "/tmp/media_cli.py")

    assert_equal "LiquidAI/LFM3-Audio-2B", audio.model_name
    assert_equal "LiquidAI/LFM3-Omni-2B", omni.model_name
    assert_equal %w[audio], audio.modalities
    assert_equal %w[image video audio], omni.modalities

    assert_raises(ArgumentError) do
      Runes::LLM::VisionAdapter.new(model: "LiquidAI/LFM3-1.7B")
    end
    assert_raises(ArgumentError) do
      Runes::LLM::AudioAdapter.new(model: "LiquidAI/LFM3-VL-2B")
    end
    assert_raises(ArgumentError) do
      Runes::LLM::OmniAdapter.new(model: "LiquidAI/d1-Omni-2B")
    end
  end

  def test_one_media_input_per_call
    adapter = Runes::LLM::VisionAdapter.new(mode: :command, cli: "/tmp/media_cli.py")

    error = assert_raises(ArgumentError) { adapter.call(["a.png", "b.png"]) }
    assert_includes error.message, "one media input"
  end

  def test_chunking_adds_offset_and_length
    Dir.mktmpdir("media-") do |dir|
      audio = File.join(dir, "clip.wav")
      File.binwrite(audio, "WAV")
      seen = nil
      runner = lambda do |argv, _stdin|
        seen = argv
        ["[00:12] bonjour", "", status]
      end
      adapter = Runes::LLM::AudioAdapter.new(
        mode: :command, cli: "/tmp/media_cli.py", python: "/bin/sh", runner: runner
      )

      result = adapter.call(audio, chunk: { offset: 10, length: 20 })

      assert result[:ok]
      assert_equal "10", seen[seen.index("--chunk-offset") + 1]
      assert_equal "20", seen[seen.index("--chunk-length") + 1]
      assert_equal({ "offset" => 10, "length" => 20 }, result[:artifact]["chunk"])
      assert_equal "time:10", result[:artifact]["anchors"].first
    end
  end

  def test_omni_keeps_one_allowed_modality_and_lists_both_senses
    Dir.mktmpdir("media-") do |dir|
      video = File.join(dir, "talk.mp4")
      File.binwrite(video, "MP4")
      runner = ->(_argv, _stdin) { ["[00:01] speech\nframe:0", "", status] }
      adapter = Runes::LLM::OmniAdapter.new(
        mode: :command, cli: "/tmp/media_cli.py", python: "/bin/sh", runner: runner
      )

      result = adapter.call(video)

      assert result[:ok]
      assert_equal "video", result[:artifact]["modality"]
      assert_equal %w[audio video], result[:artifact]["modalities"]
      assert_equal %w[image video audio], result[:modalities]
    end
  end

  def test_unreadable_media_is_a_decline_and_never_calls_the_model
    called = false
    runner = lambda do |_argv, _stdin|
      called = true
      ["", "", status]
    end
    adapter = Runes::LLM::VisionAdapter.new(
      mode: :command, cli: "/tmp/media_cli.py", python: "/bin/sh", runner: runner
    )

    result = adapter.call("/definitely/missing/image.png")

    refute result[:ok]
    assert_equal :declined, result[:status]
    assert_equal :needs_vision, result[:decision].reason_code
    assert_nil result[:artifact]
    refute called
  end

  def test_missing_media_is_a_typed_decline
    adapter = Runes::LLM::AudioAdapter.new(mode: :command, cli: "/tmp/media_cli.py")

    result = adapter.call(nil)

    refute result[:ok]
    assert_equal :declined, result[:status]
    assert_equal :needs_audio, result[:decision].reason_code
  end

  def test_a_failed_command_keeps_the_common_contract
    runner = ->(_argv, _stdin) { ["", "boom", status(2)] }
    adapter = Runes::LLM::VisionAdapter.new(
      mode: :command, cli: "/tmp/media_cli.py", python: "/bin/sh", runner: runner
    )
    Dir.mktmpdir("media-") do |dir|
      image = File.join(dir, "image.png")
      File.binwrite(image, "PNG")

      result = adapter.call(image)

      refute result[:ok]
      assert_equal :infra, result[:status]
      assert_includes result[:error], "exited 2"
      assert_equal "LiquidAI/LFM3-VL-2B", result[:family]
    end
  end

  def test_from_env_uses_the_family_variable
    adapter = Runes::LLM::VisionAdapter.from_env(
      "LFM3_VL_MODEL" => "LiquidAI/LFM3-VL-2B",
      "LFM3_MODE" => "server",
      "LFM3_BASE_URL" => "http://127.0.0.1:8080"
    )

    assert_equal "LiquidAI/LFM3-VL-2B", adapter.model_name
    assert_equal :server, adapter.mode
  end
end
