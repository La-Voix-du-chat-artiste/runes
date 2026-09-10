# frozen_string_literal: true

require_relative "test_helper"

require_relative "../lib/runes/transport/topic_filter"

# The topic matcher is the one thing every delivery decision depends on: the
# in-process hub, the MQTT adapters, the embedded broker and the capability
# guard all route through it now. Before doc5.md X5-4 there were three
# implementations that disagreed with each other and with MQTT 3.1.1, so
# this file is deliberately a conformance matrix rather than a few examples.
class TopicFilterTest < Minitest::Test
  TF = Runes::Transport::TopicFilter

  # [filter, topic, expected]
  MATRIX = [
    # plain matching
    ["a/b", "a/b", true],
    ["a/b", "a/c", false],
    ["a/b", "a/b/c", false],
    ["a/b/c", "a/b", false],

    # '+' is exactly one level, including an empty one
    ["a/+", "a/b", true],
    ["a/+", "a/", true],
    ["a/+", "a", false],
    ["a/+", "a/b/c", false],
    ["+/b", "a/b", true],
    ["+", "a", true],
    ["+", "a/b", false],

    # '#' covers the remainder, including no remainder at all
    ["a/#", "a/b", true],
    ["a/#", "a/b/c", true],
    ["a/#", "a", true],
    ["a/#", "a/", true],
    ["#", "a", true],
    ["#", "a/b/c", true],

    # trailing empty levels are real levels (guard used to invert these)
    ["a/", "a/", true],
    ["a/", "a", false],
    ["a//b", "a//b", true],
    ["a//b", "a/b", false],

    # '#' is only valid as the final level: a malformed filter matches
    # nothing rather than acting as a wildcard (in-process and broker used
    # to over-match here)
    ["a/#/b", "a/x/b", false],
    ["a/#/b", "a/#/b", false],
    ["#/b", "a/b", false],

    # MQTT 3.1.1 §4.7.2: a leading wildcard must not match a '$' topic
    ["#", "$a2a/v1/discovery/x/y/z", false],
    ["#", "$SYS/broker/uptime", false],
    ["+/card", "$a2a/card", false],
    ["+", "$SYS", false],
    ["$a2a/#", "$a2a/v1/discovery/x/y/z", true],
    ["$SYS/#", "$SYS/broker/uptime", true],
    ["a/+", "a/$b", true],

    # a topic that merely starts with '$' after a level is ordinary
    ["runes/#", "runes/prompts", true],
    ["runes/+", "runes/prompts", true]
  ].freeze

  def test_conformance_matrix
    MATRIX.each do |filter, topic, expected|
      assert_equal expected, TF.match?(filter, topic),
                   "expected match?(#{filter.inspect}, #{topic.inspect}) == #{expected}"
    end
  end

  def test_empty_topic_never_matches
    refute TF.match?("#", ""), "'#' must not match the empty topic"
    refute TF.match?("+", ""), "'+' must not match the empty topic"
    refute TF.match?("", ""), "an empty filter matches nothing"
  end

  def test_malformed_filters_are_reported
    refute TF.valid_filter?("a/#/b")
    refute TF.valid_filter?("#/b")
    refute TF.valid_filter?("")
    assert TF.valid_filter?("a/#")
    assert TF.valid_filter?("#")
    assert TF.valid_filter?("a/+/b")
    assert TF.valid_filter?("a/")
  end

  def test_shared_filter_round_trips
    wire = TF.shared_filter("workers", "runes/prompts")

    assert_equal "$share/workers/runes/prompts", wire
    assert_equal ["workers", "runes/prompts"], TF.split_shared(wire)
    assert TF.shared?(wire)
    # `match?` accepts either form, so callers cannot forget to strip it.
    assert TF.match?(wire, "runes/prompts")
    refute TF.match?(wire, "runes/other")
  end

  # A group name is one topic level. Before this check, a '/' in
  # RUNES_PROMPT_GROUP silently rewrote the subscription to a different
  # filter and the fleet went deaf (T5-8).
  def test_a_group_with_a_separator_is_rejected
    ["a/b", "a+b", "a#b", "a\u0000b", ""].each do |bad|
      assert_raises(ArgumentError, "group #{bad.inspect} must be rejected") do
        TF.shared_filter(bad, "runes/prompts")
      end
    end

    assert_equal "workers-1", TF.shared_filter("workers-1", "x")[/\A\$share\/([^\/]+)/, 1]
  end

  # `$share/<group>/<filter>` is ambiguous when read: "$share/a/b/x" is
  # either group "a" with filter "b/x" (correct) or a group "a/b" with
  # filter "x" (what a typo intended). A reader cannot tell, so the WRITER
  # is what must refuse to produce it — which is why shared_filter raises.
  def test_the_ambiguity_is_prevented_by_the_writer_not_the_reader
    group, inner = TF.split_shared("$share/a/b/x")

    assert_equal "a", group, "the reader takes the first level as the group"
    assert_equal "b/x", inner

    assert_raises(ArgumentError) { TF.shared_filter("a/b", "x") }
  end

  def test_valid_topic_rejects_wildcards
    assert TF.valid_topic?("runes/prompts/x1")
    refute TF.valid_topic?("runes/+/x1")
    refute TF.valid_topic?("runes/#")
    refute TF.valid_topic?("")
    refute TF.valid_topic?("a\u0000b")
  end
end
