# frozen_string_literal: true
require_relative 'test_helper'
require_relative '../lib/runes/json_pure'

# Two jobs (docs/spinel/spec-tier-a.md):
#
#  1. Static subset linter: every kernel file stays inside the Spinel
#     subset (§BLOCKED). This is the CI gate that keeps the kernel
#     compilable without a spinel binary on every dev box.
#  2. Parity: the pure backends (JSON parser/generator, SHA-256) produce
#     the same results as stdlib/OpenSSL, so a compiled kernel behaves
#     identically to the CRuby harness.
class SpinelSubsetTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  KERNEL_FILES = %w[
    lib/runes/compat.rb
    lib/runes/json_facade.rb
    lib/runes/json_pure.rb
    lib/runes/sha256_facade.rb
    lib/runes/random_facade.rb
    lib/runes/native.rb
    lib/runes/native/spinel_ffi.rb
    lib/runes/process_spawner.rb
    lib/runes/security/crypto_backend.rb
    lib/runes/security/crypto_backends/native.rb
    lib/runes/security/ed25519_der.rb
    lib/runes/security/nonce_cache.rb
    lib/runes/security/envelope.rb
    lib/runes/security/identity.rb
    lib/runes/security/trust_store.rb
    lib/runes/security/rpc_auth.rb
    lib/runes/security/command_policy.rb
    lib/runes/request_ledger.rb
    lib/runes/guard_telemetry.rb
    lib/runes/capabilities/guard.rb
    lib/runes/kanban.rb
    lib/runes/doc_store.rb
    lib/runes/index.rb
    lib/runes/transport/topic_filter.rb
    lib/runes/core/json_scan.rb
    lib/runes/core/plan_parser.rb
    lib/runes/core/settings_store.rb
    lib/runes/transport/base.rb
    lib/runes/transport/in_process.rb
    lib/runes/runtime.rb
    lib/runes/telemetry.rb
    lib/runes/workflow_policy.rb
    lib/runes/plugin.rb
    lib/runes/rune.rb
    lib/runes/process_spawner.rb
    lib/runes/process_runner.rb
    lib/runes/workflow/errors.rb
    lib/runes/workflow/util.rb
    lib/runes/workflow/cog.rb
    lib/runes/workflow/workflow_params.rb
    lib/runes/workflow/task.rb
    lib/runes/workflow/cog_input_context.rb
    lib/runes/workflow/system_rune.rb
    lib/runes/workflow/config_manager.rb
    lib/runes/workflow/execution_manager.rb
    lib/runes/workflow/workflow.rb
    lib/runes/workflow_kernel.rb
    lib/runes/plugins/ruby.rb
    lib/runes/plugins/cmd.rb
    lib/runes/plugins/call.rb
    lib/runes/plugins/map.rb
    lib/runes/plugins/repeat.rb
    spin/selfcheck.rb
    spin/kernel.rb
  ].freeze

  # docs/spinel/spec-tier-a.md §BLOCKED — keep in sync. `define_method` with
  # a LITERAL name is allowed (Spinel supports it); a computed name matches
  # the `[a-z_@]` after the paren and fails the gate.
  BLOCKED = [
    [/\bmethod_missing\b/, 'method_missing'],
    [/\bdefine_(?:singleton_)?method\(\s*[a-z_@]/, 'define_method/define_singleton_method with a computed name'],
    [/\beval\(\s*['"]/, 'eval'],
    [/\b(?:instance|class|module)_eval\(\s*[^&\s]/, '*_eval with a non-block argument'],
    [/\bsend\b|\bpublic_send\b|\b__send__\b/, 'send/public_send'],
    [/\bconst_set\b|\bconst_get\(\s*[a-z_@"]|\bconst_defined\?\(\s*[a-z_@"]|\bconst_missing\b/, 'dynamic const access'],
    [/\bautoload\b/, 'autoload'],
    [/\bkeyword_init\b/, 'keyword_init Struct'],
    [/\bStruct\.new\b/, 'Struct.new'],
    [/\bmodule_function\b/, 'module_function'],
    [/^\s*def\s+[a-zA-Z0-9_.?=]+\s+=\s+\S/, 'endless method def'],
    [/require\s*['"](?:json|openssl|digest|securerandom|fileutils|date|open3|socket|net\/http|uri|timeout|tmpdir|pathname|set|erb)['"]/, 'stdlib require outside the subset'],
    # Pre-empted at the first Spinel build (docs/spinel-compatibility.md):
    # cheap to replace now, so the VERIFY list only holds genuinely
    # uncertain items.
    [/&:/, 'Symbol#to_proc'],
    [/\.b\b/, 'String#b (encoding method)'],
    [/\beach_with_object\b/, 'each_with_object'],
    [/\btransform_keys\b/, 'Hash#transform_keys'],
    [/^\s*.*\.tap\b/, 'Object#tap']
  ].freeze

  # Comment lines are documentation, not code — a blocked *word* in prose
  # must not fail the gate (e.g. spec text quoting `module_function`).
  def code_only(source)
    source.lines.reject { |line| line.strip.start_with?('#') }.join
  end

  def kernel_sources
    KERNEL_FILES.map { |rel| [rel, code_only(File.read(File.join(ROOT, rel)))] }
  end

  def test_kernel_files_exist
    KERNEL_FILES.each do |rel|
      assert File.file?(File.join(ROOT, rel)), "kernel file missing: #{rel}"
    end
  end

  def test_blocked_constructs_absent
    kernel_sources.each do |rel, source|
      BLOCKED.each do |pattern, name|
        assert_nil source.match(pattern), "#{rel} uses blocked construct #{name} (docs/spinel/spec-tier-a.md §BLOCKED)"
      end
    end
  end

  def test_require_closure_is_kernel_only
    kernel_sources.each do |rel, source|
      source.scan(/require_relative\s+['"]([^'"]+)['"]/).flatten.each do |target|
        resolved = File.expand_path(target, File.join(ROOT, File.dirname(rel)))
        rel_resolved = resolved.sub(ROOT + File::SEPARATOR, '')
        rel_resolved += '.rb' unless rel_resolved.end_with?('.rb')
        assert_includes KERNEL_FILES, rel_resolved,
                        "#{rel} requires #{rel_resolved}, which is outside the kernel"
      end
    end
  end

  # --- pure-backend parity ---------------------------------------------

  JSON_FIXTURES = [
    '{}',
    '[]',
    '{"a":1,"b":[true,false,null],"c":{"d":"e"}}',
    '{"escaped":"quote\\" backslash\\\\ slash\\/"}',
    '{"controls":"\\b\\f\\n\\r\\t"}',
    '{"unicode":"caf\\u00e9"}',
    '{"pair":"\\ud83d\\ude00"}',
    '{"n":-12,"f":1.5,"e":1e3,"E":-2.5E-2,"big":123456789012345678901234567890}',
    '[1, 2.25, "three", {"four": [4]}]',
    '{"dup":1,"dup":2}'
  ].freeze

  def test_json_pure_parse_matches_stdlib
    JSON_FIXTURES.each do |fixture|
      assert_equal ::JSON.parse(fixture), Runes::JSONPure.parse(fixture), "JSONPure diverges on #{fixture}"
    end
  end

  def test_json_pure_rejects_what_stdlib_rejects
    ['', '{', '[1,]', '{"a"}', '{"a":1,}', 'tru', '"abc', '{"a" 1}', '01', '1 2', '{"a":1} x'].each do |bad|
      assert_raises(Runes::Json::ParseError, "JSONPure accepted #{bad.inspect}") do
        Runes::JSONPure.parse(bad)
      end
      assert_raises(::JSON::ParserError, "stdlib accepted #{bad.inspect}") do
        ::JSON.parse(bad)
      end
    end
  end

  def test_json_pure_nesting_limit_matches_stdlib
    # stdlib (json 3.x) does not count the outermost container: N containers
    # fit when N <= max + 1. JSONPure matches exactly (parity-pinned).
    assert_equal ::JSON.parse('[[[[]]]]', max_nesting: 3), Runes::JSONPure.parse('[[[[]]]]', max_nesting: 3)
    assert_raises(Runes::Json::ParseError) { Runes::JSONPure.parse('[[[[]]]]', max_nesting: 2) }
    assert_raises(::JSON::ParserError) { ::JSON.parse('[[[[]]]]', max_nesting: 2) }
  end

  def test_json_pure_generate_matches_stdlib
    objects = [1, 'plain', 'q"s', "line\nfeed", { 'k' => [true, nil, 1.5] }, { sym: 's' }, [], {}]
    objects.each do |obj|
      assert_equal ::JSON.generate(obj), Runes::JSONPure.generate(obj), "JSONPure.generate diverges on #{obj.inspect}"
    end
    assert_equal ::JSON.generate('é'), Runes::JSONPure.generate('é')
  end

  def test_sha256_pure_matches_openssl
    vectors = ['', 'abc', 'hello world', 'a' * 1000]
    vectors.each do |input|
      assert_equal OpenSSL::Digest::SHA256.hexdigest(input), Runes::SHA256::Pure.hex(input)
    end
  end

  def test_sha256_known_vector
    assert_equal 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                 Runes::SHA256.hex('')
  end

  def test_compat_civil_dates_match_time
    [0, 86_400, 1_761_300_000, Time.utc(1999, 12, 31).to_i, Time.utc(2026, 9, 30).to_i].each do |seconds|
      expected = Time.at(seconds).utc.strftime('%Y-%m-%d')
      assert_equal expected, Runes::Compat.utc_date(Time.at(seconds)), "civil date wrong for #{seconds}"
    end
  end

  def test_compat_iso8601_shape
    stamp = Runes::Compat.utc_iso8601(Time.at(1_761_300_000).utc)
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, stamp)
  end

  def test_compat_mkdir_p_and_basename
    Dir.mktmpdir do |dir|
      nested = File.join(dir, 'a', 'b', 'c')
      Runes::Compat.mkdir_p(nested)
      assert File.directory?(nested)
    end
    assert_equal 'run.rb', Runes::Compat.basename('/x/y/run.rb')
    assert_equal 'run.rb', Runes::Compat.basename('run.rb')
  end

  def test_random_hex_shape
    hex = Runes::Random.hex(16)
    assert_equal 32, hex.length
    assert_match(/\A[0-9a-f]+\z/, hex)
    refute_equal Runes::Random.hex(16), Runes::Random.hex(16)
    bytes = Runes::Random::PRNGPure.bytes(24)
    assert_equal 24, bytes.length
  end

  # --- build smoke -------------------------------------------------------

  def test_kernel_selfcheck_passes_under_cruby
    output = `#{RbConfig.ruby} #{File.join(ROOT, 'spin', 'kernel_cruby.rb')} selfcheck 2>&1`
    assert $?.success?, "self-check failed:\n#{output}"
    assert_includes output, 'KERNEL SELFCHECK OK'
  end

  def test_spinel_build_when_compiler_available
    spinel = ENV['SPINEL'] || which('spinel')
    skip 'no spinel binary on PATH (set SPINEL=/path/to/spinel to enable)' if spinel.nil?

    output = `#{RbConfig.ruby} #{File.join(ROOT, 'scripts', 'spinel_build.rb')} 2>&1`
    assert $?.success?, "spinel build failed:\n#{output}"
    assert_includes output, 'KERNEL SELFCHECK OK'
  end

  private

  def which(cmd)
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |dir|
      path = File.join(dir, cmd)
      return path if File.file?(path) && File.executable?(path)
    end
    nil
  end
end
