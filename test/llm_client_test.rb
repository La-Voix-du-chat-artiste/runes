require_relative 'test_helper'
require_relative '../lib/runes/core/llm_client'

class TestLLMClient < Minitest::Test
  ROUTER_ENV_KEYS = %w[SYNTHETIC SYNTHETIC_API_KEY CEREBRAS CEREBRAS_API_KEY
                       RUNES_DEFAULT_PROVIDER RUNES_DEFAULT_MODEL RUNES_DEFAULT_VARIATION].freeze

  def setup
    # Pin the process ENV so values from other suites or the ambient shell
    # cannot leak into routing decisions (the suite is offline by design).
    @saved_env = ROUTER_ENV_KEYS.to_h { |k, v| [k, v && ENV[k]] }
    ROUTER_ENV_KEYS.to_h { |k, _| [k, ENV[k]] }
    @saved_env = ROUTER_ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ROUTER_ENV_KEYS.each { |k| ENV.delete(k) }

    # Fake settings object so we don't touch disk / .env.
    @settings = Object.new
    def @settings.get(key, default = nil) = (@store ||= {})[key] || default
    def @settings.env(key) = (@env ||= {})[key]
    def @settings.set(k, v) = (@store ||= {})[k] = v
    def @settings.set_env(k, v) = (@env ||= {})[k] = v

    @settings.set('default_provider', 'cerebras')
    @settings.set('default_model', 'llama-3.3-70b')
    @settings.set('default_variation', 'high')
    @settings.set_env('CEREBRAS_API_KEY', 'test-key')

    @client = Runes::Core::LLMClient.new(@settings)
  end

  def teardown
    ROUTER_ENV_KEYS.each { |k| v = @saved_env[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # We don't hit the network in tests — stub `http.request` to return
  # canned responses so we can exercise the parsing logic.

  def test_builtin_schemas_shape
    schemas = Runes::Core::LLMClient.builtin_schemas
    assert_kind_of Array, schemas
    names = schemas.map { |s| s.dig(:function, :name) }
    assert_includes names, 'write_file'
    assert_includes names, 'read_file'
    assert_includes names, 'run_command'

    write = schemas.find { |s| s.dig(:function, :name) == 'write_file' }
    assert_equal %w[path content].sort, write.dig(:function, :parameters, :required).sort
  end

  def test_builtin_schemas_accepts_extra
    extra = [{ type: 'function', function: { name: 'echo', parameters: { type: 'object' } } }]
    schemas = Runes::Core::LLMClient.builtin_schemas(extra: extra)
    assert_equal 4, schemas.size
    assert_equal 'echo', schemas.last.dig(:function, :name)
  end

  def test_returns_structured_error_when_no_provider_key
    @settings.set_env('CEREBRAS_API_KEY', nil)
    @settings.set_env('CEREBRAS', nil)
    @settings.set_env('SYNTHETIC_API_KEY', nil)
    @settings.set_env('SYNTHETIC', nil)
    res = @client.call('hello')
    refute res[:ok]
    assert_includes res[:error], 'no LLM provider key found'
  end

  def test_unsupported_provider_returns_error
    @settings.set('default_provider', 'unknown-ai')
    res = @client.call('hello')
    refute res[:ok]
    assert_includes res[:error], 'unsupported provider'
  end

  # L7: a non-Array messages argument must produce a structured error,
  # not a confusing TypeError from inside the HTTP layer.
  def test_chat_rejects_non_array_messages
    res = @client.chat({ 'role' => 'user', 'content' => 'hi' })
    refute res[:ok]
    assert_includes res[:error], 'Array of {role, content}'
  end

  # L3: the timeout is evaluated lazily and tolerates garbage.
  def test_http_timeout_is_lazy_and_safe
    @settings.set_env('RUNES_LLM_TIMEOUT_S', 'abc')
    assert_equal Runes::Core::LLMClient::DEFAULT_HTTP_TIMEOUT_S, @client.send(:http_timeout_s)
    @settings.set_env('RUNES_LLM_TIMEOUT_S', '2')
    assert_equal 2.0, @client.send(:http_timeout_s)
  end

  # L5: notices are bounded and handed out as a defensive copy.
  def test_notices_are_bounded_and_copied
    Runes::Core::LLMClient::MAX_NOTICES.succ.times { @client.send(:notice, "n#{rand}") }
    list = @client.notices
    assert_operator list.size, :<=, Runes::Core::LLMClient::MAX_NOTICES
    refute_same @client.notices, list
  end

  # S-L1: provider error bodies are truncated and control-char scrubbed.
  def test_error_bodies_are_sanitized
    dirty = "boom \e[2J\e[3;Hspoof" + ('x' * 2000)
    clean = @client.send(:sanitize_error_body, dirty)
    refute clean.match?(/[\x00-\x08\x0b-\x1f\x7f]/)
    assert_operator clean.length, :<=, Runes::Core::LLMClient::MAX_ERROR_BODY_CHARS + 1
  end

  # S-L2: cross-provider fallback can be disabled.
  def test_provider_fallback_opt_out
    @settings.set_env('CEREBRAS_API_KEY', nil)
    @settings.set_env('SYNTHETIC', 'syn-key')
    @settings.set_env('RUNES_ALLOW_PROVIDER_FALLBACK', '0')
    assert_nil @client.resolve_route
    assert_includes @client.notices.last, 'fallback is disabled'
  end

  # S-L3: oversized untrusted JSON is not parsed.
  def test_safe_parse_json_caps_size
    small = JSON.generate('a' => 1)
    assert_equal({ 'a' => 1 }, @client.send(:safe_parse_json, small))
    big = '{"a":"' + ('x' * (Runes::Core::LLMClient::MAX_RESPONSE_BYTES + 1)) + '"}'
    assert_nil @client.send(:safe_parse_json, big), 'oversized bodies must not be parsed'
  end
end
