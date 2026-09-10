require_relative 'test_helper'
require_relative '../lib/runes/core/plan_parser'

class TestPlanParser < Minitest::Test
  def setup
    @parser = Runes::Core::PlanParser.new
  end

  def test_parses_json_steps
    raw = '{"steps":[{"tool":"write_file","args":{"path":"a.rb","content":"x"}},{"tool":"run_command","args":{"cmd":"ls"}}]}'
    steps = @parser.parse(raw)
    assert_equal 2, steps.size
    assert_equal 'write_file', steps[0][:tool]
    assert_equal({ 'path' => 'a.rb', 'content' => 'x' }, steps[0][:args])
    assert_equal 'run_command', steps[1][:tool]
  end

  def test_parses_json_embedded_in_prose
    raw = "Sure! Here's the plan:\n```json\n{\"steps\":[{\"tool\":\"read_file\",\"args\":{\"path\":\"a\"}}]}\n```\nLet me know."
    steps = @parser.parse(raw)
    assert_equal 1, steps.size
    assert_equal 'read_file', steps[0][:tool]
  end

  def test_parses_legacy_text_format
    raw = <<~TEXT
      TOOL: run_command
      ARGS: mkdir -p tmp
      ---
      TOOL: write_file
      ARGS: {"path": "tmp/a.rb", "content": "puts 1"}
      ---
    TEXT
    steps = @parser.parse(raw)
    assert_equal 2, steps.size
    assert_equal 'run_command', steps[0][:tool]
    assert_equal({ 'cmd' => 'mkdir -p tmp' }, steps[0][:args])
    assert_equal 'write_file', steps[1][:tool]
    assert_equal 'puts 1', steps[1][:args]['content']
  end

  def test_parses_legacy_pipe_format
    raw = "TOOL: write_file\nARGS: tmp/a.rb|puts 1\n---\n"
    steps = @parser.parse(raw)
    assert_equal 1, steps.size
    assert_equal({ 'path' => 'tmp/a.rb', 'content' => 'puts 1' }, steps[0][:args])
  end

  def test_returns_empty_on_nil
    assert_equal [], @parser.parse(nil)
    assert_equal [], @parser.parse('')
    assert_equal [], @parser.parse('random prose with no structure')
  end

  def test_skips_steps_without_tool
    raw = '{"steps":[{"args":{"path":"x"}},{"tool":"read_file","args":{"path":"y"}}]}'
    steps = @parser.parse(raw)
    assert_equal 1, steps.size
    assert_equal 'read_file', steps[0][:tool]
  end

  # L1: braces inside string values must not close the object early.
  def test_braces_inside_strings_do_not_truncate_the_plan
    css = 'body { margin: 0 }'
    raw = JSON.generate('steps' => [{ 'tool' => 'write_file',
                                      'args' => { 'path' => 'style.css', 'content' => css } }])
    steps = @parser.parse(raw)
    refute_empty steps, 'a } inside a string value must not end the JSON scan'
    assert_equal css, steps[0][:args]['content']
  end

  # L2: string-encoded args that fail to parse must not silently become {}.
  def test_unparseable_string_args_keep_raw_payload
    raw = '{"steps":[{"tool":"run_command","args":"{\"cmd\": TRUNCATED"}]}'
    steps = @parser.parse(raw)
    assert_equal 1, steps.size
    refute_equal({}, steps[0][:args], 'malformed args must not be replaced silently')
    assert steps[0][:args]['_raw']
  end

  # L6: multi-line JSON ARGS blobs in legacy plans must not be truncated.
  def test_legacy_multiline_args_are_kept_whole
    raw = <<~TEXT
      TOOL: write_file
      ARGS: {
        "path": "a.rb",
        "content": "puts 1"
      }
      ---
    TEXT
    steps = @parser.parse(raw)
    assert_equal 1, steps.size
    assert_equal 'a.rb', steps[0][:args]['path']
    assert_equal 'puts 1', steps[0][:args]['content']
  end
end
