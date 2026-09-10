require_relative 'test_helper'

class TestCapabilitiesGuard < Minitest::Test
  def setup
    @policy = {
      'default_allow' => false,
      'tools' => {
        'calc_tool' => {
          'mqtt_publish' => ['runes/tools/calc/response'],
          'mqtt_subscribe' => ['runes/tools/+/request']
        }
      }
    }
    @guard = Runes::Capabilities::Guard.new
    @guard.instance_variable_set(:@policy, @policy)
  end

  def test_allowed_publish
    assert @guard.allowed?('calc_tool', :mqtt_publish, 'runes/tools/calc/response')
  end

  def test_allowed_subscribe_with_wildcard
    assert @guard.allowed?('calc_tool', :mqtt_subscribe, 'runes/tools/echo/request')
  end

  def test_disallowed_publish
    refute @guard.allowed?('calc_tool', :mqtt_publish, 'runes/system/secrets')
  end

  def test_unknown_tool_denied_by_default
    refute @guard.allowed?('unknown', :mqtt_publish, 'runes/tools/calc/response')
  end

  def test_unknown_action_denied
    refute @guard.allowed?('calc_tool', :mqtt_connect, 'runes/tools/x')
  end

  def test_nil_inputs_denied
    refute @guard.allowed?(nil, :mqtt_publish, 'runes/tools/x')
    refute @guard.allowed?('calc_tool', nil, 'runes/tools/x')
    refute @guard.allowed?('calc_tool', :mqtt_publish, nil)
  end

  def test_default_policy_is_default_deny
    g = Runes::Capabilities::Guard.new
    refute g.allowed?('anything', :mqtt_publish, 'any/topic')
  end

  # --- S5-3: a policy that cannot be parsed must not fail open -------------

  def test_a_corrupt_policy_does_not_leave_the_builtin_baseline_in_place
    dir = Dir.mktmpdir('runes-guard-')
    path = File.join(dir, 'policy.json')
    File.write(path, '{ this is not json')

    g = Runes::Capabilities::Guard.new(path)

    assert g.policy_unreadable, 'the guard must say the policy was unusable'
    refute g.allowed?('write_file', :fs_write, 'anything.txt'),
           'a JSON typo must not leave write_file wide open'
    refute g.allowed?('read_file', :fs_read, '/etc/passwd')
    refute g.allowed?('run_command', :exec, 'rm -rf ..')
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir) && dir.start_with?(Dir.tmpdir)
  end

  def test_a_missing_policy_keeps_the_documented_baseline
    g = Runes::Capabilities::Guard.new(File.join(Dir.tmpdir, 'runes-no-such-policy.json'))

    refute g.policy_unreadable, 'a missing file means "not configured", not "broken"'
    assert g.allowed?('write_file', :fs_write, 'notes.txt')
    refute g.allowed?('unknown_tool', :execute, 'x')
  end

  # --- X5-4: the guard and the broker agree on what a filter means ---------

  def guard_with(patterns)
    Runes::Capabilities::Guard.new(nil, additional_fragments: [
      { 'tools' => { 't' => { 'mqtt_publish' => patterns } } }
    ])
  end

  def test_a_trailing_slash_rule_matches_the_topic_it_names
    g = guard_with(['runes/prompts/'])

    assert g.allowed?('t', :mqtt_publish, 'runes/prompts/')
    refute g.allowed?('t', :mqtt_publish, 'runes/prompts'),
           'a trailing-slash rule must not grant the shorter topic (was fail-open)'
  end

  def test_a_malformed_filter_matches_nothing
    g = guard_with(['a/#/b'])

    refute g.allowed?('t', :mqtt_publish, 'a/x/b'), "'#' is only a wildcard as the final level"
    refute g.allowed?('t', :mqtt_publish, 'a/#/b')
  end

  def test_a_leading_wildcard_does_not_match_dollar_topics
    g = guard_with(['#'])

    refute g.allowed?('t', :mqtt_publish, '$a2a/v1/discovery/org/unit/agent'),
           'MQTT 3.1.1 §4.7.2: a leading wildcard must not match a $-topic'
    assert g.allowed?('t', :mqtt_publish, 'runes/prompts')
  end

  def test_one_level_wildcard_matches_an_empty_level
    g = guard_with(['a/+'])

    assert g.allowed?('t', :mqtt_publish, 'a/')
    assert g.allowed?('t', :mqtt_publish, 'a/b')
    refute g.allowed?('t', :mqtt_publish, 'a')
  end
end
