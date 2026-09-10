# frozen_string_literal: true

# Packaging + LLM-adapter seam tests.
#
# Hermetic: no network, no broker, no database, no ruby_llm. test_helper
# points RUNES_ROOT at a throwaway tree and strips provider keys. The
# wasmtime-missing case runs in a CHILD process because this process already
# loaded wasmtime through test_helper (we shadow the gem with a fake
# `wasmtime.rb` instead of uninstalling anything).
require 'test_helper'
require 'open3'
require 'rbconfig'

# Allow `ruby -Itest test/packaging_test.rb` without -Ilib too.
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'runes'

class PackagingTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # Taken from .gitignore: secrets and local runtime state must never ship.
  FORBIDDEN_PREFIXES = %w[
    config/.env
    log/
    tmp/
    workspace/
    runes_observer/
    docs/epics/
    docs/missions/
  ].freeze
  FORBIDDEN_BASENAMES = %w[runes.db ruby.wasm].freeze

  FakeSettings = Struct.new(:env_values) do
    def env(key) = env_values[key]
    def get(_key, default = nil) = default
  end

  class FakeAdapter
    attr_reader :settings

    def initialize(settings = nil)
      @settings = settings
    end
  end

  def setup
    @saved_adapter = ENV['RUNES_LLM_ADAPTER']
  end

  def teardown
    # Assigning nil deletes the variable.
    ENV['RUNES_LLM_ADAPTER'] = @saved_adapter
  end

  # --- gemspec -----------------------------------------------------------

  def test_gemspec_loads_with_expected_identity
    spec = gemspec

    assert_equal 'runes', spec.name
    assert_equal Runes::VERSION, spec.version.to_s
    assert_equal 'MIT', spec.license
    refute_nil spec.summary
    refute_nil spec.homepage
    assert spec.required_ruby_version.satisfied_by?(Gem::Version.new('3.3')),
           "expected required_ruby_version #{spec.required_ruby_version} to allow Ruby 3.3"
    assert_equal ['lib'], spec.require_paths
    assert_equal 'bin', spec.bindir
    assert_equal spec.homepage, spec.metadata['source_code_uri']
    refute_nil spec.metadata['changelog_uri']
  end

  def test_gemspec_has_the_expected_executables
    # Every binstub in bin/ must be listed in the gemspec, or users install
    # the gem and cannot run it (runes-acl shipped nowhere until Phase 17).
    expected = %w[runes runes-client runes-daemon runes-mcp runes-replay runes-acl runes-workflow]
    assert_equal expected.sort, gemspec.executables.sort
    assert_equal Dir.children(File.join(ROOT, 'bin')).reject { |f| f.start_with?('.') }.sort,
                 gemspec.executables.sort,
                 'bin/ and the gemspec executable list disagree'
    gemspec.executables.each do |exe|
      assert File.file?(File.join(ROOT, 'bin', exe)), "missing executable bin/#{exe}"
    end
  end

  def test_runtime_dependencies_are_explicit_and_wasmtime_is_optional
    names = gemspec.runtime_dependencies.map(&:name)
    assert_includes names, 'mqtt'
    assert_includes names, 'sqlite3'
    assert_includes names, 'dotenv'
    refute_includes names, 'wasmtime', 'wasmtime must stay an optional dependency'
    mqtt = gemspec.runtime_dependencies.find { |d| d.name == 'mqtt' }
    assert_equal Gem::Requirement.new('~> 0.7'), mqtt.requirement
  end

  def test_files_allow_list_excludes_secrets_and_local_state
    files = gemspec.files

    assert_includes files, 'lib/runes.rb'
    assert_includes files, 'lib/runes/llm.rb'
    assert_includes files, 'lib/runes/llm/ruby_llm_adapter.rb'
    assert_includes files, 'README.md'
    assert_includes files, 'config/.env.example'
    assert_includes files, 'config/policy.json'
    assert files.any? { |f| f.start_with?('tools/') }, 'tools/ should ship'
    assert files.any? { |f| f.start_with?('examples/') }, 'examples/ should ship'

    assert_empty files.grep(%r{\A(config/\.env(?![.\w])|log/|tmp/|workspace/|runes_observer/|docs/(epics|missions)/)}),
                 'packaged file list leaks secrets or local state'
    assert_empty files.select { |f| FORBIDDEN_BASENAMES.include?(File.basename(f)) },
                 'packaged file list leaks a local binary/database'
    assert_empty files.grep(/\.gem\z/)

    # The allow-list must be relative, unique and real.
    assert_equal files.uniq, files
    assert(files.none? { |f| f.start_with?('/') })
    files.each { |f| assert File.file?(File.join(ROOT, f)), "gemspec lists a missing file: #{f}" }
  end

  # --- entry point ------------------------------------------------------

  def test_require_runes_succeeds_offline
    assert defined?(Runes::VERSION)
    assert defined?(Runes::Core::LLMClient)
    assert defined?(Runes::LLM)
  end

  def test_require_runes_succeeds_when_wasmtime_is_missing
    Dir.mktmpdir('runes-no-wasm') do |dir|
      # A fake wasmtime.rb that fails to load, placed first on $LOAD_PATH:
      # simulates "gem not installed" without touching the real gem.
      File.write(File.join(dir, 'wasmtime.rb'),
                 'raise LoadError, "cannot load such file -- wasmtime (packaging_test shadow)"')

      lib = File.join(ROOT, 'lib')
      script = "require 'runes'; puts \"RUNES_OK=#{Runes::VERSION}\""
      out, status = Open3.capture2e(RbConfig.ruby, "-I#{dir}", "-I#{lib}", '-e', script)

      assert status.success?, "child failed without wasmtime:\n#{out}"
      assert_includes out, 'RUNES_OK='
      assert_includes out, 'wasmtime', 'expected a clear warning naming the missing gem'
    end
  end

  # --- LLM adapter seam -------------------------------------------------

  def test_default_adapter_is_the_builtin_router
    ENV.delete('RUNES_LLM_ADAPTER')
    adapter = Runes::LLM.adapter(fake_settings)
    assert_instance_of Runes::Core::LLMClient, adapter
  end

  def test_ruby_llm_adapter_is_unavailable_without_the_gem
    ENV['RUNES_LLM_ADAPTER'] = 'ruby_llm'
    error = assert_raises(Runes::LLM::AdapterUnavailable) do
      Runes::LLM.adapter(fake_settings)
    end
    assert_includes error.message, 'ruby_llm'
    assert_includes error.message, 'RUNES_LLM_ADAPTER'
  end

  def test_registered_adapter_is_selected_when_registered
    Runes::LLM.register(:fake, FakeAdapter)
    ENV['RUNES_LLM_ADAPTER'] = 'fake'

    settings = fake_settings
    adapter = Runes::LLM.adapter(settings)
    assert_instance_of FakeAdapter, adapter
    assert_same settings, adapter.settings

    # Explicit name: wins over the env var.
    ENV['RUNES_LLM_ADAPTER'] = 'builtin'
    assert_instance_of FakeAdapter, Runes::LLM.adapter(settings, name: :fake)
  end

  def test_unknown_adapter_name_raises_actionable_error
    ENV['RUNES_LLM_ADAPTER'] = 'definitely-not-registered'
    error = assert_raises(Runes::LLM::AdapterUnavailable) { Runes::LLM.adapter(fake_settings) }
    assert_includes error.message, 'RUNES_LLM_ADAPTER'
    assert_includes error.message, 'registered adapters'
  end

  def test_ruby_llm_adapter_class_loads_without_ruby_llm
    require 'runes/llm/ruby_llm_adapter'
    klass = Runes::LLM::RubyLLMAdapter

    assert_equal 'ruby_llm', klass.gem_name
    refute klass.available?, 'ruby_llm is not installed in the test environment'
    refute klass.new(fake_settings).available?

    # Constructing the adapter (the built-in default) must not require the gem.
    assert_instance_of klass, klass.new(fake_settings)
  end

  private

  def gemspec
    @gemspec ||= Gem::Specification.load(File.join(ROOT, 'runes.gemspec'))
  end

  def fake_settings
    FakeSettings.new({})
  end
end
