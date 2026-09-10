# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/runes/workflow" # the runes register themselves here

# The plugin registry is the seam the workflow DSL is built on: every Roast
# cog is registered here as a `kind: :rune` plugin (see docs/WORKFLOWS.md).
#
# `reset!` now rebuilds the registry atomically from the declared set
# (X5-3), so these tests can assert on the registry exactly instead of
# working around leaked registrations from other test files.
class PluginTest < Minitest::Test
  # A rune-named fixture that satisfies the registry's own invariant
  # (`every :rune plugin is a Runes::Rune`) even if it leaks to other tests.
  class Sample < Runes::Rune
    plugin :plugin_test_sample, description: "a sample rune"

    def execute(input) = input
  end

  class Other < Runes::Plugin
    plugin :plugin_test_other, kind: :tool, description: "not a rune"
  end

  BUILTIN_RUNES = %i[agent call chat cmd map repeat ruby].freeze

  def teardown
    # Leave the registry exactly as the harness declared it.
    Runes::Plugin.reset!
  end

  def test_the_seven_roast_runes_are_registered_as_rune_plugins
    names = Runes::Plugin.names(kind: :rune)

    BUILTIN_RUNES.each { |name| assert_includes names, name }
    Runes::Plugin.all(kind: :rune).each do |definition|
      assert_operator definition.klass, :<, Runes::Rune,
                      "#{definition} is a :rune but not a Runes::Rune"
    end
  end

  def test_declaration_registers_under_name_and_kind
    assert Runes::Plugin.registered?(:plugin_test_sample)
    assert Runes::Plugin.registered?(:plugin_test_sample, kind: :rune)
    refute Runes::Plugin.registered?(:plugin_test_sample, kind: :tool)

    assert_equal Sample, Runes::Plugin[:plugin_test_sample]
    assert_equal Sample, Runes::Plugin.fetch(:plugin_test_sample).klass
  end

  def test_an_undeclared_plugin_derives_its_name_from_the_class
    klass = Class.new(Runes::Plugin)
    def klass.name = "Runes::Plugins::DoTheThing"

    assert_equal :do_the_thing, klass.plugin_name
    assert_equal :plain, klass.plugin_kind # not a rune unless declared
  end

  def test_declared_name_and_kind_are_readable
    assert_equal :plugin_test_sample, Sample.plugin_name
    assert_equal :rune, Sample.plugin_kind
    assert_equal "tool:plugin_test_other", Other.new.describe
  end

  def test_kinds_are_separate_namespaces
    assert_includes Runes::Plugin.names(kind: :rune), :plugin_test_sample
    assert_includes Runes::Plugin.names(kind: :tool), :plugin_test_other
    refute_includes Runes::Plugin.names(kind: :tool), :plugin_test_sample
    refute_includes Runes::Plugin.names(kind: :rune), :plugin_test_other
  end

  def test_all_returns_definitions_with_metadata
    definition = Runes::Plugin.all(kind: :rune).find { |d| d.name == :plugin_test_sample }

    refute_nil definition
    assert_equal :rune, definition.kind
    assert_equal "a sample rune", definition.description
    assert_equal "rune:plugin_test_sample", definition.to_s
  end

  def test_unknown_plugin_fails_loudly
    error = assert_raises(Runes::Plugin::UnknownPlugin) { Runes::Plugin.fetch(:nope) }

    assert_includes error.message, "no rune plugin named :nope"
    assert_includes error.message, "plugin_test_sample"
    assert_nil Runes::Plugin[:nope]
  end

  def test_a_different_class_cannot_silently_take_a_name
    conflict = Class.new(Runes::Plugin)

    error = assert_raises(Runes::Plugin::DefinitionError) do
      Runes::Plugin.register(conflict, name: :plugin_test_sample, kind: :rune)
    end
    assert_includes error.message, "already registered"
    assert_equal Sample, Runes::Plugin[:plugin_test_sample]
  end

  def test_replace_swaps_the_class_without_leaving_a_stale_definition
    replacement = Class.new(Runes::Rune)
    Runes::Plugin.register(replacement, name: :plugin_test_sample, kind: :rune, replace: true)

    assert_equal replacement, Runes::Plugin[:plugin_test_sample]
    assert_equal 1, Runes::Plugin.all(kind: :rune).count { |d| d.name == :plugin_test_sample }
  end

  def test_redeclaring_the_same_class_is_idempotent
    Runes::Plugin.register(Sample, name: :plugin_test_sample, kind: :rune)

    assert_equal 1, Runes::Plugin.all(kind: :rune).count { |d| d.name == :plugin_test_sample }
  end

  def test_reset_keeps_declarations_and_drops_runtime_registrations
    ad_hoc = Class.new(Runes::Plugin)
    Runes::Plugin.register(ad_hoc, name: :plugin_test_ad_hoc, kind: :tool)
    assert Runes::Plugin.registered?(:plugin_test_ad_hoc, kind: :tool)

    Runes::Plugin.reset!

    refute Runes::Plugin.registered?(:plugin_test_ad_hoc, kind: :tool),
           "reset! must drop runtime registrations"
    BUILTIN_RUNES.each do |name|
      assert Runes::Plugin.registered?(name),
             "reset! must not lose the declared built-in rune #{name}"
    end
  end

  # --- X5-3: reset! is atomic ------------------------------------------

  def test_reset_rebuilds_the_registry_from_the_declared_set_exactly
    Runes::Plugin.reset!

    expected = Runes::Plugin.declared
                              .each_with_object({}) { |klass, seen| seen[[klass.plugin_kind, klass.plugin_name]] = true }
                              .keys.sort
    actual = Runes::Plugin.all(kind: nil).map { |definition| [definition.kind, definition.name] }.sort

    assert_equal expected, actual, "reset! must rebuild exactly the declared plugins"
    BUILTIN_RUNES.each { |name| assert_includes actual.map(&:last), name }
  end

  def test_reset_survives_a_shadowed_declaration_and_keeps_every_builtin
    first = Class.new(Runes::Rune)
    first.plugin :plugin_test_shared
    second = Class.new(Runes::Rune)
    second.plugin :plugin_test_shared, replace: true
    later = Class.new(Runes::Rune)
    later.plugin :plugin_test_later

    failures = Runes::Plugin.reset!

    assert_empty failures, "a shadowed declaration must not abort the rebuild"
    assert_equal second, Runes::Plugin[:plugin_test_shared], "the last declaration wins"
    assert Runes::Plugin.registered?(:plugin_test_later), "the later declaration must survive"
    BUILTIN_RUNES.each do |name|
      assert Runes::Plugin.registered?(name), "reset! must not lose the built-in rune #{name}"
    end
  ensure
    [first, second, later].each { |klass| Runes::Plugin.declared.delete(klass) }
    Runes::Plugin.reset!
  end

  def test_a_failed_declaration_is_not_recorded
    conflict = Class.new(Runes::Plugin)
    declared_before = Runes::Plugin.declared.dup

    assert_raises(Runes::Plugin::DefinitionError) do
      conflict.plugin :plugin_test_sample
    end

    assert_equal declared_before, Runes::Plugin.declared,
                 "a failed plugin declaration must not poison every later reset!"
  end

  def test_instance_carries_context_and_options
    plugin = Other.new(context: :ctx, size: 3)

    assert_equal :ctx, plugin.context
    assert_equal({ size: 3 }, plugin.options)
  end

  def test_execute_is_abstract_on_the_base_class
    assert_raises(NotImplementedError) { Runes::Plugin.new.execute }
  end

  # --- the extension story, end to end ---------------------------------
  #
  # This is the example in docs/WORKFLOWS.md. It is a test so the documented
  # way to add a verb cannot rot: if the Input/Output contract changes, this
  # fails rather than the docs silently lying.

  class Greet < Runes::Rune
    plugin :plugin_test_greet, description: "Say hello"

    class Input < Runes::Cog::Input
      attr_accessor :name

      def validate!
        raise InvalidInputError, "'name' is required" if name.nil?
      end

      def coerce(input_return_value)
        super
        @name = input_return_value.to_s
      end
    end

    class Output < Runes::Cog::Output
      attr_reader :text

      def initialize(text)
        super()
        @text = text
      end

      def raw_text = text
    end

    def execute(input) = Output.new("hello #{input.name}")
  end

  def test_a_third_party_rune_is_usable_from_a_workflow_with_no_engine_change
    source = <<~RUBY
      execute do
        plugin_test_greet(:greeting) { "world" }
        outputs { |_value, _index| plugin_test_greet!(:greeting).text }
      end
    RUBY

    dir = Dir.mktmpdir("runes-plugin-")
    begin
      path = File.join(dir, "workflow.rb")
      File.write(path, source)
      workflow = Runes::Workflow.from_file(path, Runes::WorkflowParams.new)
      assert_equal "hello world", workflow.final_output
    ensure
      FileUtils.remove_entry(dir) if Dir.exist?(dir) && dir.start_with?(Dir.tmpdir)
    end
  end
end
