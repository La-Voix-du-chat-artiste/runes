# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/runes/workflow"

# A probe rune used only by these tests: it echoes its configuration so the
# config merge precedence can be asserted from inside a workflow. It is
# registered under a unique name so the built-in runes never need a reset.
class WorkflowEngineProbe < Runes::Rune
  plugin :workflow_engine_probe

  class Input < Runes::Cog::Input
    def validate!; end

    def coerce(input_return_value)
      super
      @returned = input_return_value
    end
  end

  class Output < Runes::Cog::Output
    attr_reader :config_values, :returned

    def initialize(config_values, returned)
      super()
      @config_values = config_values
      @returned = returned
    end

    def raw_text
      "(probe #{config_values.inspect})"
    end
  end

  protected

  def execute(input)
    Output.new(@config.values, input.instance_variable_get(:@returned))
  end
end

class WorkflowEngineTest < Minitest::Test
  def setup
    Runes::Workflow.register_builtin_runes!
    WorkflowEngineProbe.plugin :workflow_engine_probe unless Runes::Plugin.registered?(:workflow_engine_probe)
    @dirs = []
    $runes_engine_order = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if Dir.exist?(dir) }
  end

  # --- helpers --------------------------------------------------------

  def build_workflow(source, files = {})
    dir = Dir.mktmpdir("runes-engine-")
    @dirs << dir
    files.each do |relative, content|
      path = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    File.write(File.join(dir, "workflow.rb"), source)
    File.join(dir, "workflow.rb")
  end

  def run_workflow(source, params = Runes::WorkflowParams.new, files = {})
    Runes::Workflow.from_file(build_workflow(source, files), params)
  end

  # --- plugin registry ------------------------------------------------

  def test_plugin_registry_exposes_runes
    assert_includes Runes::Plugin.names(kind: :rune), :ruby
    assert_equal Runes::Rune, Runes::Cog
    assert Runes::Plugin.all(kind: :rune).all? { |definition| definition.klass < Runes::Rune }
    assert Runes::Cog::Output.const_defined?(:WithText)
    assert Runes::Cog::Output.const_defined?(:WithJson)
    assert Runes::Cog::Output.const_defined?(:WithNumber)
    assert Runes::Cog::Input.const_defined?(:InvalidInputError)
  end

  # --- execute ordering ----------------------------------------------

  def test_execute_blocks_accumulate_and_run_in_order
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { $runes_engine_order << :a; 1 }
        ruby(:b) { $runes_engine_order << :b; 2 }
      end
      execute do
        ruby(:c) { $runes_engine_order << :c; 3 }
      end
    RUBY

    assert_equal %i[a b c], $runes_engine_order
    assert_equal 3, workflow.final_output.value
    assert workflow.completed?
  end

  def test_named_execute_scope_does_not_run_at_top_level
    run_workflow(<<~RUBY)
      execute(:unused) { ruby(:never) { $runes_engine_order << :never } }
      execute { ruby(:top) { $runes_engine_order << :top; 1 } }
    RUBY

    assert_equal %i[top], $runes_engine_order
  end

  def test_anonymous_rune_gets_a_fallback_name
    rune = Runes::Plugins::Ruby.new(nil, nil, anonymous: true)
    assert rune.anonymous?
    assert_match(/\A[0-9a-f-]{36}\z/, rune.name.to_s)

    workflow = run_workflow(<<~RUBY)
      execute do
        ruby { 5 }
        ruby(:named) { 6 }
      end
    RUBY
    assert_equal 6, workflow.final_output.value
  end

  # --- input coercion -------------------------------------------------

  def test_block_return_value_is_coerced_and_my_input_object_works
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:coerced) { 42 }
        ruby(:assigned) { |my| my.value = "assigned" }
        outputs { |_value, _index| [ruby!(:coerced).value, ruby!(:assigned).value] }
      end
    RUBY

    assert_equal [42, "assigned"], workflow.final_output
  end

  def test_explicitly_nil_block_return_is_accepted_after_coerce
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:nothing) { nil }
        outputs { |_value, _index| ruby!(:nothing).value }
      end
    RUBY

    assert_nil workflow.final_output
  end

  # --- output accessors ----------------------------------------------

  def test_bang_accessor_raises_for_unknown_name
    error = assert_raises(Runes::CogDoesNotExistError) do
      run_workflow(<<~RUBY)
        execute { ruby(:a) { ruby!(:nope) } }
      RUBY
    end
    assert_equal "nope", error.message
  end

  def test_bang_accessor_raises_for_not_yet_run_rune
    assert_raises(Runes::CogNotYetRunError) do
      run_workflow(<<~RUBY)
        execute do
          ruby(:a) { ruby!(:b) }
          ruby(:b) { 1 }
        end
      RUBY
    end
  end

  def test_accessors_report_skipped_and_failed
    skipped = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { skip! }
        ruby(:b) { [ruby(:a).nil?, ruby?(:a)] }
        outputs { |_value, _index| ruby!(:b).value }
      end
    RUBY
    assert_equal [true, false], skipped.final_output

    assert_raises(Runes::CogSkippedError) do
      run_workflow(<<~RUBY)
        execute do
          ruby(:a) { skip! }
          ruby(:b) { ruby!(:a) }
        end
      RUBY
    end

    failed = run_workflow(<<~RUBY)
      config { ruby(:a) { continue_on_failure! } }
      execute do
        ruby(:a) { fail! }
        ruby(:b) { [ruby(:a).nil?, ruby?(:a)] }
        outputs { |_value, _index| ruby!(:b).value }
      end
    RUBY
    assert_equal [true, false], failed.final_output

    assert_raises(Runes::CogFailedError) do
      run_workflow(<<~RUBY)
        config { ruby(:a) { continue_on_failure! } }
        execute do
          ruby(:a) { fail! }
          ruby(:b) { ruby!(:a) }
        end
      RUBY
    end
  end

  def test_bang_accessor_returns_a_deep_copy
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { { list: [1, 2] } }
        ruby(:b) { copy = ruby!(:a).value[:list]; copy << 3; copy }
        outputs { |_value, _index| [ruby!(:a).value, ruby!(:b).value] }
      end
    RUBY

    assert_equal [{ list: [1, 2] }, [1, 2, 3]], workflow.final_output
  end

  # --- control flow ---------------------------------------------------

  def test_skip_marks_rune_skipped_and_continues
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { skip!("nothing to do") }
        ruby(:b) { 2 }
        outputs { |_value, _index| [ruby?(:a), ruby!(:b).value] }
      end
    RUBY

    assert_equal [false, 2], workflow.final_output
  end

  def test_fail_aborts_by_default_and_can_continue
    assert_raises(Runes::ControlFlow::FailCog) do
      run_workflow(<<~RUBY)
        execute do
          ruby(:a) { fail!("boom") }
          ruby(:b) { $runes_engine_order << :b }
        end
      RUBY
    end
    assert_empty $runes_engine_order

    $runes_engine_order = []
    run_workflow(<<~RUBY)
      config { ruby(:a) { continue_on_failure! } }
      execute do
        ruby(:a) { fail!("boom") }
        ruby(:b) { $runes_engine_order << :b }
      end
    RUBY
    assert_equal %i[b], $runes_engine_order
  end

  def test_abort_on_failure_can_be_disabled_with_no_abort_on_failure
    run_workflow(<<~RUBY)
      config { ruby(:a) { no_abort_on_failure! } }
      execute do
        ruby(:a) { fail! }
        ruby(:b) { $runes_engine_order << :b }
      end
    RUBY

    assert_equal %i[b], $runes_engine_order
  end

  def test_next_and_break_stop_the_scope_without_raising
    %i[next break].each do |verb|
      $runes_engine_order = []
      workflow = run_workflow(<<~RUBY)
        execute do
          ruby(:a) { #{verb}! }
          ruby(:b) { $runes_engine_order << :b; 2 }
        end
      RUBY

      assert_empty $runes_engine_order, "#{verb}! should stop the scope"
      assert_nil workflow.final_output
    end
  end

  def test_break_is_swallowed_like_next_at_top_level
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { 1 }
        ruby(:b) { break! }
        outputs { |_value, _index| "done" }
      end
    RUBY

    assert_equal "done", workflow.final_output
  end

  # --- outputs --------------------------------------------------------

  def test_default_final_output_is_the_last_runes_output
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:first) { "first" }
        ruby(:last) { "last" }
      end
    RUBY

    assert_equal "last", workflow.final_output.value
  end

  def test_outputs_defines_the_scope_return_value
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { 2 }
        outputs { |scope_value, scope_index| [ruby!(:a).value * 3, scope_value.class, scope_index] }
      end
    RUBY

    assert_equal [6, Runes::WorkflowParams, 0], workflow.final_output
  end

  def test_outputs_swallows_access_errors_but_outputs_bang_raises
    swallowed = run_workflow(<<~RUBY)
      execute do
        ruby(:a) { skip! }
        outputs { |_value, _index| ruby!(:a) }
      end
    RUBY
    assert_nil swallowed.final_output

    assert_raises(Runes::CogSkippedError) do
      run_workflow(<<~RUBY)
        execute do
          ruby(:a) { skip! }
          outputs! { |_value, _index| ruby!(:a) }
        end
      RUBY
    end
  end

  def test_defining_both_outputs_forms_raises
    assert_raises(Runes::ExecutionManager::OutputsAlreadyDefinedError) do
      run_workflow(<<~RUBY)
        execute do
          ruby(:a) { 1 }
          outputs { |_value, _index| 1 }
          outputs! { |_value, _index| 2 }
        end
      RUBY
    end
  end

  # --- config merge precedence ---------------------------------------

  def test_config_merge_precedence
    workflow = run_workflow(<<~RUBY)
      config do
        global { async! }
        workflow_engine_probe { no_async! }
        workflow_engine_probe(/^p/) { continue_on_failure! }
        workflow_engine_probe(/p$/) { abort_on_failure! }
        workflow_engine_probe(:p) { async! }
      end
      execute do
        workflow_engine_probe(:p)
        outputs { |_value, _index| workflow_engine_probe!(:p).config_values }
      end
    RUBY

    values = workflow.final_output
    # global async -> general no_async -> /^p/ continue -> /p$/ abort -> :p async
    assert_equal true, values[:async]
    assert_equal true, values[:abort_on_failure]
  end

  def test_regexp_configs_merge_in_insertion_order
    workflow = run_workflow(<<~RUBY)
      config do
        workflow_engine_probe(/^p/) { abort_on_failure! }
        workflow_engine_probe(/p/) { no_abort_on_failure! }
      end
      execute do
        workflow_engine_probe(:p)
        outputs { |_value, _index| workflow_engine_probe!(:p).config_values }
      end
    RUBY

    assert_equal false, workflow.final_output[:abort_on_failure]
  end

  def test_config_block_accessors_receive_workflow_params
    params = Runes::WorkflowParams.new([], [], { name: "World" })
    files = { "prompts/greeting.md.erb" => "Hello <%= name %>" }
    workflow = run_workflow(<<~RUBY, params, files)
      config do
        global do
          raise "no kwargs" unless kwarg(:name) == "World"
          raise "bad kwarg?" unless kwarg?(:name) && !kwarg?(:missing)
          raise "bad template" unless template("greeting", name: "World") == "Hello World"
        end
      end
      execute { ruby(:a) { 1 } }
    RUBY

    assert_equal 1, workflow.final_output.value
  end

  # --- async ----------------------------------------------------------

  def test_async_rune_runs_concurrently_and_blocks_on_access
    # If `async!` were a no-op (sync), `slow` would finish before `fast`
    # started; asserting that `slow` observed `fast`'s side effect proves the
    # runes really run concurrently (W5-12).
    $runes_fast_done = false
    $runes_slow_saw_fast = false

    workflow = run_workflow(<<~RUBY)
      config { ruby(:slow) { async! }; ruby(:fast) { async! } }
      execute do
        ruby(:slow) { sleep 0.2; $runes_slow_saw_fast = $runes_fast_done; 99 }
        ruby(:fast) { $runes_fast_done = true; 7 }
        ruby(:reader) { ruby!(:slow).value }
        outputs { |_value, _index| [ruby!(:reader).value, ruby!(:fast).value, $runes_slow_saw_fast] }
      end
    RUBY

    assert_equal [99, 7, true], workflow.final_output
  end

  # --- async failure ordering + execution-manager cleanup -------------

  def test_async_failure_surfaces_in_completion_order_not_start_order
    # `slow` starts first and sleeps; `boom` fails almost immediately. Waiting
    # in start order would block for the full sleep before surfacing the
    # failure (W5-5).
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(RuntimeError) do
      run_workflow(<<~RUBY)
        config { ruby(:slow) { async! }; ruby(:boom) { async! } }
        execute do
          ruby(:slow) { sleep 1.0; 1 }
          ruby(:boom) { raise "FAST" }
          outputs { |_value, _index| ruby!(:slow).value }
        end
      RUBY
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "FAST", error.message
    assert_operator elapsed, :<, 0.6, "the fast failure must not wait for the slow task"
  end

  def test_execution_manager_restores_state_when_outputs_bang_raises
    previous_group = Runes::TaskGroup.current
    error = assert_raises(RuntimeError) do
      run_workflow(<<~RUBY)
        execute do
          ruby(:a) { raise "ORIGINAL" }
          outputs! { |_value, _index| raise "outputs boom" }
        end
      RUBY
    end

    assert_equal "ORIGINAL", error.message, "the original exception must win (W5-4)"
    assert_group_restored(previous_group, "the thread-local TaskGroup must be restored")
  end

  def test_execution_manager_restores_state_when_final_output_computation_fails
    previous_group = Runes::TaskGroup.current
    assert_raises(Runes::CogDoesNotExistError) do
      run_workflow("execute { }")
    end

    assert_group_restored(previous_group,
                          "a cleanup failure must still restore the thread-local TaskGroup")
  end

  # --- W5-7 / W5-8: TaskGroup stop semantics ----------------------------

  def test_async_after_stop_does_not_run_the_block
    group = Runes::TaskGroup.new
    ran = false
    group.stop

    task = group.async { ran = true }
    sleep 0.15

    refute ran, "a task created after stop must not execute its block (W5-8)"
    assert task.stopped?
    refute task.started?, "no thread may be created for it"
    assert_nil task.wait
  end

  def test_stop_reports_stragglers_without_waiting_and_drain_joins_them
    group = Runes::TaskGroup.new
    finished = false
    group.async do
      sleep 0.6
      finished = true
    end
    sleep 0.05

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outstanding = group.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 1, outstanding.size, "the rune still in flight must be reported (W5-7)"
    assert_operator elapsed, :<, 0.4,
                    "stop must not block on a running rune: a fast failure must not wait for a slow sibling (W5-5)"
    assert_equal [], group.drain(timeout: 5), "drain joins it"
    assert finished, "the rune finished on its own"
  end

  # --- W5-6: the Bundler env swap is process-wide, so it must be serialised

  def test_concurrent_spawns_do_not_corrupt_the_bundler_environment
    before = ENV["BUNDLE_GEMFILE"]

    results = 4.times.map do
      Thread.new do
        Runes::CommandRunner.execute("ruby", args: ["-e", "print ENV['BUNDLE_GEMFILE'].to_s"])
      end
    end.map(&:value)

    results.each { |result| assert result.status.success?, "each spawn must succeed" }
    # `assert_equal nil` trips Minitest's style guard, and BUNDLE_GEMFILE is
    # legitimately absent outside `bundle exec`.
    if before.nil?
      assert_nil ENV["BUNDLE_GEMFILE"], "the ENV swap must not invent a gemfile"
    else
      assert_equal before, ENV["BUNDLE_GEMFILE"],
                   "Bundler.with_unbundled_env mutates the process ENV; concurrent spawns must not interleave (W5-6)"
    end
  end

  # --- config manager -------------------------------------------------

  def test_anonymous_runes_in_a_repeat_do_not_grow_name_scoped_configs
    # Before W5-11 each iteration's UUID-named anonymous rune created one
    # name-scoped config entry (60 iterations -> 61 entries). Named runes are
    # still scoped normally, so the only entry is the `repeat` itself.
    workflow = run_workflow(<<~RUBY)
      config { ruby { no_abort_on_failure! } }
      execute(:tick) { ruby { 1 } }
      execute { repeat(:loop, run: :tick) { |my| my.value = 0; my.max_iterations = 60 } }
    RUBY

    name_scoped = workflow.config_manager.instance_variable_get(:@name_scoped_configs)
    total = name_scoped.values.sum(&:size)
    assert_operator total, :<=, 2, "config entries grew with anonymous runes: #{name_scoped.inspect}"
  end

  # --- W5-13: deep_dup / name guard -----------------------------------

  def test_deep_dup_returns_io_thread_and_mutex_as_is
    reader, writer = IO.pipe
    mutex = Mutex.new
    thread = Thread.new { sleep 0.05 }
    begin
      result = Runes.deep_dup([reader, writer, mutex, thread])
      assert_same reader, result[0]
      assert_same writer, result[1]
      assert_same mutex, result[2]
      assert_same thread, result[3]
    ensure
      thread.join
      reader.close
      writer.close
    end
  end

  def test_a_rune_name_that_shadows_a_context_method_is_rejected
    shadow = Class.new(Runes::Rune) do
      def execute(_input); end
    end
    Runes::Plugin.register(shadow, name: :template, kind: :rune)
    begin
      error = assert_raises(Runes::CogInputContext::IllegalRuneNameError) do
        run_workflow("execute { ruby(:a) { 1 } }")
      end

      assert_includes error.message, "template"
    ensure
      Runes::Plugin.reset!
    end
  end

  # --- map parallel ---------------------------------------------------

  def test_map_parallel_uses_a_bounded_pool_of_workers
    # The parallel path had zero coverage; pre-fix it spawned one thread per
    # item (807 for 800 items at parallel(4)). The pool must be O(n), and the
    # results must still be complete and in item order (W5-2).
    baseline = Thread.list.size
    $runes_map_thread_peaks = []
    workflow = run_workflow(<<~RUBY)
      config { map(:rows) { parallel(2) } }
      execute(:probe) do
        ruby(:probe) do |_my, _value, _index|
          $runes_map_thread_peaks << Thread.list.size
          sleep 0.005
          1
        end
      end
      execute do
        map(:rows, run: :probe) { |my| my.items = (1..40).to_a }
        outputs { |_value, _index| collect(map!(:rows)).map(&:value) }
      end
    RUBY

    assert_equal Array.new(40, 1), workflow.final_output
    peak = $runes_map_thread_peaks.max
    assert_operator peak, :<=, baseline + 12,
                    "parallel(2) must bound live threads (baseline #{baseline}, peak #{peak})"
    assert_operator peak, :<, baseline + 40, "the pool must not be one thread per item"
  end

  # --- repeat guard / timeouts ----------------------------------------

  def test_cmd_timeout_kills_a_too_long_command_and_reports_it
    dir = Dir.mktmpdir("runes-timeout-")
    @dirs << dir
    marker = File.join(dir, "finished")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    error = assert_raises(Runes::CommandRunner::TimeoutError) do
      run_workflow(<<~RUBY)
        config { cmd(:slow) { timeout(0.2) } }
        execute { cmd(:slow) { ["ruby", "-e", %(sleep 5; File.write(#{marker.inspect}, 'no'))] } }
      RUBY
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_includes error.message, "timed out"
    assert_operator elapsed, :<, 3.0
    sleep 0.1
    refute File.exist?(marker), "the command must be killed, not merely abandoned"
  end

  def test_repeat_is_bounded_by_an_explicit_iteration_guard
    $runes_repeat_iterations = 0
    error = assert_raises(Runes::Plugins::Repeat::IterationLimitExceededError) do
      run_workflow(<<~RUBY)
        config { repeat(:loop) { max_iterations(3) } }
        execute(:tick) { ruby(:n) { $runes_repeat_iterations += 1 } }
        execute { repeat(:loop, run: :tick) { |my| my.value = 0 } }
      RUBY
    end

    assert_equal 3, $runes_repeat_iterations
    assert_includes error.message, "exceeded 3 iterations"
  end

  def test_repeat_timeout_bounds_a_runaway_loop
    assert_raises(Runes::Plugins::Repeat::TimeoutError) do
      run_workflow(<<~RUBY)
        config { repeat(:loop) { timeout(0.2) } }
        execute(:tick) { ruby(:n) { sleep 0.15; 1 } }
        execute { repeat(:loop, run: :tick) { |my| my.value = 0 } }
      RUBY
    end
  end

  # --- ruby rune output delegation -----------------------------------

  def test_ruby_output_delegates_to_value_and_hash
    workflow = run_workflow(<<~RUBY)
      execute do
        ruby(:text) { "alpha\\nbeta" }
        ruby(:hash) { { foo: 1, bar: ->(n) { n * 2 } } }
        ruby(:proc) { ->(n) { n + 1 } }
        outputs do |_value, _index|
          [
            ruby!(:text).value,
            ruby!(:text).lines,
            ruby!(:hash).foo,
            ruby!(:hash)[:foo],
            ruby!(:hash).bar(3),
            ruby!(:hash).call(:bar, 4),
            ruby!(:proc).call(1)
          ]
        end
      end
    RUBY

    # `ruby` output delegates `lines` to the String value, so newlines are kept
    # (unlike `cmd`/`chat`, whose outputs include WithText and strip them).
    assert_equal ["alpha\nbeta", ["alpha\n", "beta"], 1, 1, 6, 8, 2], workflow.final_output
  end

  # --- params + template ---------------------------------------------

  def test_params_accessors_and_template
    params = Runes::WorkflowParams.new(["target-a"], [:verbose], { name: "World" })
    files = { "prompts/greeting.md.erb" => "Hello <%= name %>" }
    workflow = run_workflow(<<~RUBY, params, files)
      execute do
        ruby(:params) do
          [
            target!,
            targets,
            arg?(:verbose),
            arg?(:quiet),
            args,
            kwarg(:name),
            kwarg?(:name),
            kwarg?(:missing),
            kwargs,
            tmpdir,
            tmpdir.directory?,
            template("greeting", name: "World")
          ]
        end
        outputs { |_value, _index| ruby!(:params).value }
      end
    RUBY

    target, targets, verbose, quiet, args, name, has_name, has_missing, kwargs, tmp, is_dir, rendered =
      workflow.final_output

    assert_equal "target-a", target
    assert_equal ["target-a"], targets
    assert_equal true, verbose
    assert_equal false, quiet
    assert_equal [:verbose], args
    assert_equal "World", name
    assert_equal true, has_name
    assert_equal false, has_missing
    assert_equal({ name: "World" }, kwargs)
    assert_kind_of Pathname, tmp
    assert_equal true, is_dir
    assert_equal "Hello World", rendered
  end

  def test_missing_template_raises_context_not_found
    assert_raises(Runes::CogInputContext::ContextNotFoundError) do
      run_workflow(<<~RUBY)
        execute { ruby(:a) { template("does-not-exist") } }
      RUBY
    end
  end

  def test_kwarg_bang_and_target_bang_raise_when_missing
    assert_raises(ArgumentError) do
      run_workflow(<<~RUBY)
        execute { ruby(:a) { kwarg!(:missing) } }
      RUBY
    end

    assert_raises(ArgumentError) do
      run_workflow(<<~RUBY)
        execute { ruby(:a) { target! } }
      RUBY
    end
  end

  # --- use / local plugin loading ------------------------------------

  def test_use_loads_a_local_cog_file
    fake_source = <<~RUBY
      class WorkflowEngineFake < Runes::Rune
        plugin :workflow_engine_fake

        class Input < Runes::Cog::Input
          attr_accessor :text

          def validate!
            raise InvalidInputError, "text required" if text.nil? && !coerce_ran?
          end

          def coerce(input_return_value)
            super
            @text = input_return_value.to_s
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

        protected

        def execute(input)
          Output.new("fake:\#{input.text}")
        end
      end
    RUBY

    files = { "cogs/workflow_engine_fake.rb" => fake_source }
    workflow = run_workflow(<<~RUBY, Runes::WorkflowParams.new, files)
      use(:workflow_engine_fake)
      execute do
        workflow_engine_fake(:probe) { "hello" }
      end
    RUBY

    assert_includes Runes::Plugin.names(kind: :rune), :workflow_engine_fake
    assert_equal "fake:hello", workflow.final_output.text
  end

  def test_use_raises_for_unknown_loadable
    assert_raises(Runes::Workflow::InvalidLoadableReference) do
      run_workflow(<<~RUBY)
        use(:definitely_not_here)
        execute { ruby(:a) { 1 } }
      RUBY
    end
  end

  # --- run_file -------------------------------------------------------

  def test_run_file_returns_the_final_output
    path = build_workflow(<<~RUBY)
      execute { ruby(:a) { "done" } }
    RUBY

    assert_equal "done", Runes::Workflow.run_file(path).value
  end

  # --- command runner -------------------------------------------------

  def test_command_runner_runs_argv_without_a_shell
    result = Runes::CommandRunner.execute("ruby", args: ["-e", "print ARGV.join('-')", "a", "b"])

    assert_equal "a-b", result.out
    assert result.status.success?
    assert_equal result.to_ary, [result.out, result.err, result.status]
  end

  def test_command_runner_accepts_an_argv_array_and_streams_lines
    lines = []
    result = Runes::CommandRunner.execute(["ruby", "-e", "puts 1; puts 2"], stdout_handler: ->(line) { lines << line.strip })

    assert_equal "1\n2\n", result.out
    assert_equal %w[1 2], lines
  end

  def test_command_runner_never_uses_a_shell
    # A shell would expand this; an argv array must pass it through verbatim.
    result = Runes::CommandRunner.execute("ruby", args: ["-e", "print ARGV[0]", "$(echo pwned)"])

    assert_equal "$(echo pwned)", result.out
  end

  def test_a_one_element_array_is_not_run_through_a_shell
    # Ruby routes a single-element argv through `/bin/sh`; Runes must not.
    # A one-element Array is a literal command name, so this is ENOENT, not a
    # redirection (W5-1).
    dir = Dir.mktmpdir("runes-shell-")
    @dirs << dir
    marker = File.join(dir, "pwned")

    assert_raises(Errno::ENOENT) do
      Runes::CommandRunner.execute(["echo INJECTED > #{marker}"])
    end
    refute File.exist?(marker), "a one-element argv must never reach a shell"
  end

  def test_a_string_command_is_split_without_a_shell
    result = Runes::CommandRunner.execute("ruby -e 'puts 1'")

    assert_equal "1\n", result.out
    assert result.status.success?
  end

  def test_a_string_command_with_metacharacters_is_refused_by_default
    error = assert_raises(Runes::CommandRunner::ShellSyntaxError) do
      Runes::CommandRunner.execute("echo hi | tr a-z A-Z")
    end

    assert_includes error.message, "metacharacter"
    assert_includes error.message, "shell: true"
  end

  def test_shell_semantics_are_available_through_the_explicit_opt_in
    result = Runes::CommandRunner.execute("echo hi | tr a-z A-Z", shell: true)

    assert_equal "HI\n", result.out
    assert result.status.success?
  end

  def test_cmd_rune_shell_opt_in_runs_a_shell_line
    workflow = run_workflow(<<~RUBY)
      config { cmd(:piped) { shell! } }
      execute do
        cmd(:piped) { "echo hi | tr a-z A-Z" }
        outputs { |_value, _index| cmd!(:piped).out }
      end
    RUBY

    assert_equal "HI\n", workflow.final_output
  end

  def test_a_hostile_kwarg_cannot_inject_a_shell_command
    # The doc5.md W5-1 reproduction, in-process and against the real runner:
    # a workflow that interpolates a CLI value into a command String must not
    # be able to create a file.
    dir = Dir.mktmpdir("runes-inject-")
    @dirs << dir
    marker = File.join(dir, "pwned")
    params = Runes::WorkflowParams.new([], [], { name: "hello; echo INJECTED > #{marker}" })

    error = assert_raises(Runes::CommandRunner::ShellSyntaxError) do
      run_workflow(<<~RUBY, params)
        execute do
          cmd(:leak) { "echo " + kwarg(:name).to_s }
          outputs { |_value, _index| cmd!(:leak).out }
        end
      RUBY
    end

    assert_includes error.message, "metacharacter"
    refute File.exist?(marker), "the hostile kwarg must not create a file"
  end

  def test_command_runner_raises_for_no_command
    assert_raises(Runes::CommandRunner::NoCommandProvidedError) do
      Runes::CommandRunner.execute("")
    end
  end

  def test_command_runner_raises_timeout
    assert_raises(Runes::CommandRunner::TimeoutError) do
      Runes::CommandRunner.execute("ruby", args: ["-e", "sleep 5"], timeout: 0.2)
    end
  end

  # --- config fields + working directory -----------------------------

  def test_config_field_generates_dual_purpose_accessors
    config_class = Class.new(Runes::Cog::Config) do
      field(:level, 3) { |value| Integer(value) }
    end

    config = config_class.new
    assert_equal 3, config.level

    config.level(7)
    assert_equal 7, config.level

    config.use_default_level!
    assert_equal 3, config.level

    assert_raises(ArgumentError) { config.level("nope") }

    config[:level] = 9
    assert_equal 9, config[:level]

    replacement = config.merge(config_class.new({ level: 1 }))
    assert_equal 9, config.level, "merge must not mutate the receiver"
    assert_equal 1, replacement.level, "the argument wins in merge"
  end

  def test_config_working_directory_validation
    config = Runes::Cog::Config.new

    config.working_directory("/definitely/not/here")
    assert_raises(Runes::Cog::Config::InvalidConfigError) { config.valid_working_directory }

    config.use_current_working_directory!
    assert_nil config.valid_working_directory

    config.working_directory(Dir.pwd)
    assert_equal Pathname.new(Dir.pwd), config.valid_working_directory
  end

  def test_config_base_options_and_deep_dup
    config = Runes::Cog::Config.new
    assert config.abort_on_failure?
    refute config.async?

    config.async!
    config.no_abort_on_failure!
    assert config.async?
    refute config.abort_on_failure?

    config.sync!
    refute config.async?

    copy = config.deep_dup
    copy.async!
    refute config.async?, "deep_dup must not share state"
  end

  # --- output modules -------------------------------------------------

  def test_output_with_text_json_and_number
    output_class = Class.new(Runes::Cog::Output) do
      include Runes::Cog::Output::WithText
      include Runes::Cog::Output::WithJson
      include Runes::Cog::Output::WithNumber

      def initialize(raw)
        super()
        @raw = raw
      end

      def raw_text = @raw
    end

    fenced = output_class.new("prelude\n```json\n{\"a\": 1, \"b\": [2, 3]}\n```\n")
    assert_equal({ a: 1, b: [2, 3] }, fenced.json)
    assert_equal({ a: 1, b: [2, 3] }, fenced.json!)
    assert_nil output_class.new("no json here").json
    assert_raises(JSON::ParserError) { output_class.new("no json here").json! }

    numbered = output_class.new("total: 1,234.6 usd")
    assert_in_delta 1234.6, numbered.float
    assert_equal 1235, numbered.integer
    assert_nil output_class.new("no number").float

    assert_equal "hello", output_class.new("  hello\n").text
    assert_equal %w[a b], output_class.new("a\nb\n").lines

    copy = fenced.deep_dup
    refute_same fenced, copy
    assert_equal fenced.json, copy.json
  end

  # --- rune contract --------------------------------------------------

  def test_rune_contract_predicates_and_type
    rune = Runes::Plugins::Ruby.new(:example, nil)

    assert_equal :example, rune.name
    assert_equal "ruby", rune.type
    refute rune.anonymous?
    refute rune.started?
    refute rune.skipped?
    refute rune.failed?
    refute rune.stopped?
    refute rune.succeeded?
    assert_nil rune.output
    assert_nil rune.wait
  end

  def test_expected_error_classes_exist
    assert_equal Runes::Rune, Runes::Cog
    assert_operator Runes::CogOutputAccessError, :<, Runes::Error
    assert_operator Runes::ExecutionManager::ExecutionManagerError, :<, Runes::Error
    assert_operator Runes::ExecutionManager::ExecutionScopeDoesNotExistError, :<,
                    Runes::ExecutionManager::ExecutionManagerError
    assert_operator Runes::ExecutionManager::ExecutionScopeNotSpecifiedError, :<,
                    Runes::ExecutionManager::ExecutionManagerError
    assert_operator Runes::ExecutionManager::OutputsAlreadyDefinedError, :<,
                    Runes::ExecutionManager::ExecutionManagerError
    assert_operator Runes::ExecutionManager::IllegalRuneNameError, :<,
                    Runes::ExecutionManager::ExecutionManagerError
    assert_operator Runes::Cog::Input::InvalidInputError, :<, Runes::Error
    assert_operator Runes::CommandRunner::CommandRunnerError, :<, Runes::Error
    assert_operator Runes::CommandRunner::NoCommandProvidedError, :<, Runes::CommandRunner::CommandRunnerError
    assert_operator Runes::CommandRunner::TimeoutError, :<, Runes::CommandRunner::CommandRunnerError
    assert_operator Runes::Workflow::WorkflowError, :<, Runes::Error
    assert_operator Runes::ControlFlow::SkipCog, :<, Runes::ControlFlow::Base
    assert_operator Runes::ControlFlow::FailCog, :<, Runes::ControlFlow::Base
    assert_operator Runes::ControlFlow::Next, :<, Runes::ControlFlow::Base
    assert_operator Runes::ControlFlow::Break, :<, Runes::ControlFlow::Base
  end

  # `assert_same nil, x` trips Minitest's "use assert_nil" guard, which is why
  # these two tests only passed when an earlier test happened to leak a group
  # into the thread-local — the order-dependence class doc5.md D5-2 describes.
  def assert_group_restored(previous, message)
    if previous.nil?
      assert_nil Runes::TaskGroup.current, message
    else
      assert_same previous, Runes::TaskGroup.current, message
    end
  end

end
