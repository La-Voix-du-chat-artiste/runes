require 'tmpdir'
require_relative 'test_helper'
require_relative '../lib/runes/core/tool_registry'

class TestToolRegistry < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('runes-tools')
    @registry = Runes::Core::ToolRegistry.new(tools_dir: @tmp)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && Dir.exist?(@tmp)
  end

  def test_empty_when_dir_missing
    reg = Runes::Core::ToolRegistry.new(tools_dir: '/nonexistent/path')
    assert reg.empty?
    assert_equal({}, reg.cards)
  end

  def test_scans_tool_directories
    write_tool('alpha', card: { 'description' => 'A tool' },
                policy: { 'mqtt_publish' => ['runes/tools/alpha/response'] })
    write_tool('beta',  card: nil,
                policy: { 'mqtt_publish' => ['runes/tools/beta/response'] })

    reg = Runes::Core::ToolRegistry.new(tools_dir: @tmp)
    refute reg.empty?
    assert_equal %w[alpha beta].sort, reg.cards.keys.sort

    # alpha had an explicit card.json
    assert_equal 'A tool', reg.cards['alpha']['description']

    # beta got a default card because card.json was missing
    assert_equal '(no card.json found)', reg.cards['beta']['description']

    # policy fragment aggregates both tools keyed by name, plus the
    # implicit `execute` grant for registered manifest tools (S-W3)
    assert_equal ['runes/tools/alpha/response'],
                 reg.policy_fragment.dig('tools', 'alpha', 'mqtt_publish')
    assert_equal ['#'], reg.policy_fragment.dig('tools', 'alpha', 'execute')
    assert_equal ['runes/tools/beta/response'],
                 reg.policy_fragment.dig('tools', 'beta', 'mqtt_publish')
  end

  def test_malformed_files_are_skipped
    dir = File.join(@tmp, 'bad')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'card.json'), '{not json')
    File.write(File.join(dir, 'capabilities.json'), 'also not json')

    reg = Runes::Core::ToolRegistry.new(tools_dir: @tmp)
    # Tool still registered (default card), but no policy
    assert_equal '(no card.json found)', reg.cards['bad']['description']
    assert_nil reg.policy_fragment.dig('tools', 'bad')
  end

  def test_execute_grant_is_not_overridden_by_manifest
    write_tool('gamma', card: nil, policy: { 'execute' => ['runes/tools/gamma/only'] })
    reg = Runes::Core::ToolRegistry.new(tools_dir: @tmp)
    assert_equal ['runes/tools/gamma/only'], reg.policy_fragment.dig('tools', 'gamma', 'execute')
  end

  private

  def write_tool(name, card:, policy:)
    dir = File.join(@tmp, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'card.json'), JSON.generate(card)) if card
    File.write(File.join(dir, 'capabilities.json'), JSON.generate(policy)) if policy
  end
end
