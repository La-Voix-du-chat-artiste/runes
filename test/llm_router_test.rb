require 'tmpdir'
require 'net/http'
require_relative 'test_helper'
require_relative '../lib/runes/core/llm_client'

# Multi-provider LLM router: registry + preference order (DeepSeek V4.1
# Flash > Synthetic > Cerebras), routing (explicit arg > env > DB >
# key-based fallback), model aliases, per-provider sampling, payload
# building, fresh-DB seeding, and the FULL call path driven through a dup
# transport — a real Net::HTTP response object with a canned body — so the
# suite never needs an API key and never touches the network.
class TestLLMRouter < Minitest::Test
  ROUTER_ENV_KEYS = %w[DEEPSEEK DEEPSEEK_API_KEY SYNTHETIC SYNTHETIC_API_KEY
                       CEREBRAS CEREBRAS_API_KEY RUNES_DEFAULT_PROVIDER
                       RUNES_DEFAULT_MODEL RUNES_DEFAULT_VARIATION].freeze

  # A canned Net::HTTP response: same class, #code/#body/[]/is_a? as the
  # wire object, no socket. This is the "dup" of the real provider call.
  def http_response(code, body, message = 'Test')
    klass = Net::HTTPResponse::CODE_TO_OBJ[code.to_s]
    resp = klass.new('1.1', code.to_s, message)
    resp.instance_variable_set(:@body, body)
    resp.instance_variable_set(:@header, {})
    resp.instance_variable_set(:@read, true)
    resp
  end

  # Transport that hands out the canned responses in order and records
  # every request it was asked to make.
  class DupTransport
    attr_reader :requests

    def initialize(*responses)
      @responses = responses.flatten
      @requests = []
    end

    def post(uri:, route:, body:, timeout_s:)
      @requests << { uri: uri, route: route, body: body, timeout_s: timeout_s }
      raise 'DupTransport ran out of canned responses' if @responses.empty?

      @responses.shift
    end
  end

  def setup
    @saved = ROUTER_ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ROUTER_ENV_KEYS.each { |k| ENV.delete(k) }

    @settings = Object.new
    def @settings.get(key, default = nil) = (@store ||= {})[key] || default
    def @settings.env(key) = (@env ||= {})[key]
    def @settings.set(k, v) = (@store ||= {})[k] = v
    def @settings.set_env(k, v) = (@env ||= {})[k] = v

    # Stale Cerebras-era preferences, as an existing runes.db would have.
    @settings.set('default_provider', 'cerebras')
    @settings.set('default_model', 'llama-3.3-70b')
    @settings.set('default_variation', 'high')
    # Exercise retry paths without paying for real backoff.
    @settings.set_env('RUNES_RETRY_BACKOFF_S', '0')

    @client = Runes::Core::LLMClient.new(@settings)
  end

  def teardown
    ROUTER_ENV_KEYS.each { |k| v = @saved[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def content_response(content, finish: 'stop', usage: { 'total_tokens' => 3 })
    JSON.generate('choices' => [{ 'message' => { 'content' => content }, 'finish_reason' => finish }],
                  'usage' => usage)
  end

  def tool_response(calls, finish: 'tool_calls')
    JSON.generate('choices' => [{ 'message' => { 'tool_calls' => calls }, 'finish_reason' => finish }])
  end

  # --- registry & preference order ---------------------------------------

  def test_registry_prefers_deepseek_then_synthetic_then_cerebras
    assert_equal %w[deepseek synthetic cerebras], Runes::Core::LLMClient::PROVIDER_PREFERENCE
    assert_equal 'deepseek-flash', Runes::Core::LLMClient::PROVIDERS['deepseek'].default_model
    assert_equal 'deepseek-flash', Runes::Core::LLMClient.seed_model_for('deepseek')
    assert_equal 'glm-5.3-flash', Runes::Core::LLMClient.seed_model_for('synthetic')
    assert_equal 'llama-3.3-70b', Runes::Core::LLMClient.seed_model_for('cerebras')
  end

  # --- routing ----------------------------------------------------------

  def test_deepseek_key_wins_over_a_stale_cerebras_preference
    @settings.set_env('DEEPSEEK', 'sk-deepseek')
    route = @client.resolve_route
    assert_equal 'deepseek', route.provider
    assert_equal 'https://api.deepseek.com/v1', route.base_url
    # DB model 'llama-3.3-70b' is unknown for deepseek -> re-derived.
    assert_equal 'deepseek-flash', route.model
  end

  def test_deepseek_wins_when_both_deepseek_and_synthetic_keys_exist
    @settings.set_env('DEEPSEEK', 'sk-deepseek')
    @settings.set_env('SYNTHETIC', 'syn-key')
    assert_equal 'deepseek', @client.resolve_route.provider
  end

  def test_falls_back_to_synthetic_when_deepseek_has_no_key
    @settings.set_env('SYNTHETIC', 'syn-key')
    route = @client.resolve_route
    assert_equal 'synthetic', route.provider
    assert_equal 'syn:large:text', route.model
    assert_includes @client.notices.join("\n"), 'falling back'
  end

  def test_falls_back_to_cerebras_when_only_cerebras_is_keyed
    @settings.set_env('CEREBRAS_API_KEY', 'cb-key')
    route = @client.resolve_route
    assert_equal 'cerebras', route.provider
  end

  def test_explicit_provider_wins_over_db_env_and_preference
    @settings.set_env('DEEPSEEK', 'sk-deepseek')
    @settings.set_env('CEREBRAS_API_KEY', 'cb_key')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'synthetic')
    route = @client.resolve_route(provider: 'cerebras')
    assert_equal 'cerebras', route.provider
    assert_equal 'llama-3.3-70b', route.model
  end

  def test_env_provider_overrides_stale_db
    @settings.set_env('SYNTHETIC', 'syn_test_key')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'synthetic')
    assert_equal 'synthetic', @client.resolve_route.provider
  end

  def test_deepseek_model_aliases
    @settings.set_env('DEEPSEEK', 'sk')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'deepseek')
    ['deepseek', 'DeepSeek-V4.1-Flash', 'v4.1-flash', 'deepseek-v4-flash', 'deepseek-v4-pro'].each do |name|
      assert_equal 'deepseek-flash', @client.resolve_route(model: name).model,
                   "alias #{name} must map to the V4.1 Flash model id"
    end
    # Pass-through ids for the provider prefix survive untouched.
    assert_equal 'deepseek-other', @client.resolve_route(model: 'deepseek-other').model
  end

  def test_unknown_explicit_provider_fails_loudly
    @settings.set_env('DEEPSEEK', 'sk')
    route = @client.resolve_route(provider: 'unknown-ai')
    assert_nil route
    assert_includes @client.notices.last, 'unsupported provider'
  end

  def test_no_keys_anywhere_returns_nil_with_notice_and_no_http
    transport = DupTransport.new
    client = Runes::Core::LLMClient.new(@settings, transport: transport)
    route = client.resolve_route
    assert_nil route
    assert_includes client.notices.last, 'no LLM provider key found'
    res = client.call('hello')
    refute res[:ok]
    assert_empty transport.requests, 'routing must fail before any HTTP attempt'
  end

  # --- sampling per provider ----------------------------------------------

  def test_deepseek_variation_maps_to_reasoning_effort
    @settings.set_env('DEEPSEEK', 'k')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'deepseek')
    assert_equal({ reasoning_effort: 'high' }, @client.resolve_route(variation: 'high').sampling_params)
    assert_equal({ reasoning_effort: 'max' },  @client.resolve_route(variation: 'max').sampling_params)
    assert_equal({ reasoning_effort: 'low' },  @client.resolve_route(variation: 'balanced').sampling_params)
    # Documented aliases from the provider's effort table.
    assert_equal({ reasoning_effort: 'high' }, @client.resolve_route(variation: 'medium').sampling_params)
    assert_equal({ reasoning_effort: 'max' },  @client.resolve_route(variation: 'ultra').sampling_params)
  end

  def test_default_variation_is_high
    @settings.set_env('DEEPSEEK', 'k')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'deepseek')
    assert_equal({ reasoning_effort: 'high' }, @client.resolve_route.sampling_params)
  end

  def test_synthetic_variation_maps_to_reasoning_effort
    @settings.set_env('SYNTHETIC', 'k')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'synthetic')
    assert_equal({ reasoning_effort: 'high' }, @client.resolve_route(variation: 'high').sampling_params)
    assert_equal({ reasoning_effort: 'max' },  @client.resolve_route(variation: 'max').sampling_params)
    assert_equal({ reasoning_effort: 'low' },  @client.resolve_route(variation: 'balanced').sampling_params)
  end

  def test_cerebras_variation_maps_to_temperature
    @settings.set_env('CEREBRAS_API_KEY', 'k')
    assert_equal({ temperature: 0.7 }, @client.resolve_route(variation: 'high').sampling_params)
    assert_equal({ temperature: 0.2 }, @client.resolve_route(variation: 'low').sampling_params)
  end

  def test_env_variation_overrides_db
    @settings.set_env('SYNTHETIC', 'k')
    @settings.set_env('RUNES_DEFAULT_PROVIDER', 'synthetic')
    @settings.set_env('RUNES_DEFAULT_VARIATION', 'max')
    assert_equal({ reasoning_effort: 'max' }, @client.resolve_route.sampling_params)
  end

  # --- payload building -----------------------------------------------------

  def test_content_mode_payload_uses_json_response_format
    @settings.set_env('DEEPSEEK', 'k')
    route = @client.resolve_route(provider: 'deepseek')
    payload = @client.build_payload(route, 'hello')
    assert_equal 'deepseek-flash', payload[:model]
    assert_equal 'high', payload[:reasoning_effort]
    refute payload.key?(:temperature)
    assert_equal({ type: 'json_object' }, payload[:response_format])
    refute payload.key?(:tools)
  end

  def test_tools_mode_payload_sends_schemas
    @settings.set_env('DEEPSEEK', 'k')
    route = @client.resolve_route(provider: 'deepseek')
    payload = @client.build_payload(route, 'hello', tools: Runes::Core::LLMClient.builtin_schemas)
    assert_equal 'auto', payload[:tool_choice]
    assert payload[:tools].is_a?(Array)
    refute payload.key?(:response_format)
  end

  def test_max_tokens_knob_is_optional
    @settings.set_env('DEEPSEEK', 'k')
    route = @client.resolve_route(provider: 'deepseek')
    refute @client.build_payload(route, 'hi').key?(:max_tokens)
    @settings.set_env('RUNES_MAX_TOKENS', '512')
    assert_equal 512, @client.build_payload(route, 'hi')[:max_tokens]
    @settings.set_env('RUNES_MAX_TOKENS', 'not-a-number')
    refute @client.build_payload(route, 'hi').key?(:max_tokens)
  end

  # --- full call path through the dup transport ------------------------------

  def test_call_parses_content_and_surfaces_usage_without_network
    @settings.set_env('DEEPSEEK', 'sk-deepseek')
    transport = DupTransport.new(http_response('200', content_response('{"steps":[]}')))
    client = Runes::Core::LLMClient.new(@settings, transport: transport)

    res = client.call('hello')
    assert res[:ok], res[:error]
    assert_equal 'deepseek', res[:provider]
    assert_equal 'deepseek-flash', res[:model]
    assert_equal '{"steps":[]}', res[:content]
    assert_equal({ 'total_tokens' => 3 }, res[:usage])
    assert_equal 'stop', res[:finish_reason]

    req = transport.requests.first
    sent = JSON.parse(req[:body])
    assert_equal 'https://api.deepseek.com/v1/chat/completions', req[:uri].to_s
    assert_equal 'sk-deepseek', req[:route].api_key
    assert_equal 'deepseek-flash', sent['model']
    assert_equal 'high', sent['reasoning_effort']
  end

  def test_call_parses_native_tool_calls
    @settings.set_env('DEEPSEEK', 'sk')
    body = tool_response([{ 'id' => 'c1', 'type' => 'function',
                            'function' => { 'name' => 'write_file',
                                            'arguments' => '{"path":"a.txt","content":"hi"}' } }])
    transport = DupTransport.new(http_response('200', body))
    client = Runes::Core::LLMClient.new(@settings, transport: transport)

    res = client.call('write a file', tools: Runes::Core::LLMClient.builtin_schemas)
    assert res[:ok], res[:error]
    assert_equal :tool_calls, res[:mode]
    assert_equal 'write_file', res[:tool_calls].first[:tool]
    assert_equal({ 'path' => 'a.txt', 'content' => 'hi' }, res[:tool_calls].first[:args])
  end

  def test_length_truncated_response_is_an_explicit_error
    @settings.set_env('DEEPSEEK', 'sk')
    transport = DupTransport.new(http_response('200', content_response('{"steps":[', finish: 'length')))
    client = Runes::Core::LLMClient.new(@settings, transport: transport)
    res = client.call('hi')
    refute res[:ok]
    assert_includes res[:error], 'truncated'
  end

  def test_truncated_tool_call_arguments_are_rejected
    @settings.set_env('DEEPSEEK', 'sk')
    body = tool_response([{ 'id' => 'c1', 'type' => 'function',
                            'function' => { 'name' => 'write_file', 'arguments' => '{"path":"a.tx' } }])
    transport = DupTransport.new(http_response('200', body))
    client = Runes::Core::LLMClient.new(@settings, transport: transport)
    res = client.call('hi', tools: Runes::Core::LLMClient.builtin_schemas)
    refute res[:ok]
    assert_includes res[:error], 'unparseable'
  end

  # --- provider error shapes (B4-2 / E4-9) ----------------------------------

  def test_provider_error_bodies_never_raise_regardless_of_shape
    @settings.set_env('DEEPSEEK', 'sk')
    bodies = [
      ['401', '{"error":"invalid api key"}',        'invalid api key'],
      ['401', '{"error":{"message":"nested"}}',     'nested'],
      ['429', '{"error":{"type":"rate_limit"}}',    'rate_limit'],
      ['400', '{"error":["bad","request"]}',        'bad'],
      ['402', '{"message":"insufficient balance"}', 'insufficient balance'],
      ['500', 'plain text failure',                 'plain text failure'],
      ['503', '',                                   'HTTP 503']
    ]
    bodies.each do |code, body, expected|
      transport = DupTransport.new(*Array.new(4) { http_response(code, body) })
      client = Runes::Core::LLMClient.new(@settings, transport: transport)
      res = client.call('hi')
      refute res[:ok], "#{code} #{body[0, 20]} must fail"
      assert_includes res[:error], expected, "#{code} #{body[0, 20]} -> #{res[:error]}"
      refute_includes res[:error], 'TypeError'
    end
  end

  def test_retryable_status_is_retried_then_succeeds
    @settings.set_env('DEEPSEEK', 'sk')
    transport = DupTransport.new(http_response('503', 'busy'),
                                 http_response('200', content_response('ok')))
    client = Runes::Core::LLMClient.new(@settings, transport: transport)
    res = client.call('hi')
    assert res[:ok], res[:error]
    assert_equal 2, transport.requests.size
  end

  # --- fresh-DB seeding ---------------------------------------------------------

  def test_fresh_db_seeds_deepseek_when_key_present
    ENV['DEEPSEEK'] = 'sk-seed' # Settings#seed_defaults reads real ENV
    root = Dir.mktmpdir('runes-seed')
    settings = Runes::Core::Settings.new(root: root)
    assert_equal 'deepseek', settings.get('default_provider')
    assert_equal 'deepseek-flash', settings.get('default_model')
    assert_equal 'high', settings.get('default_variation')
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_fresh_db_seeds_synthetic_when_only_synthetic_key_present
    ENV['SYNTHETIC'] = 'syn_seed_key'
    root = Dir.mktmpdir('runes-seed-syn')
    settings = Runes::Core::Settings.new(root: root)
    assert_equal 'synthetic', settings.get('default_provider')
    assert_equal 'glm-5.3-flash', settings.get('default_model')
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_fresh_db_seeds_cerebras_without_any_other_key
    root = Dir.mktmpdir('runes-seed2')
    settings = Runes::Core::Settings.new(root: root)
    assert_equal 'cerebras', settings.get('default_provider')
    assert_equal 'llama-3.3-70b', settings.get('default_model')
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  # R4: switching providers re-derives a stale default_model.
  def test_provider_switch_rederives_model
    root = Dir.mktmpdir('runes-switch')
    settings = Runes::Core::Settings.new(root: root)
    assert_equal 'cerebras', settings.get('default_provider')
    settings.set('default_provider', 'deepseek')
    assert_equal 'deepseek-flash', settings.get('default_model'),
                 'default_model must follow the provider switch'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  # E4-1: a stale provider preference is migrated to the first keyed
  # provider in preference order, so a Cerebras-era runes.db does not keep
  # re-deriving models once a DeepSeek key appears.
  def test_stale_provider_preference_is_migrated_to_the_keyed_provider
    root = Dir.mktmpdir('runes-migrate')
    settings = Runes::Core::Settings.new(root: root)
    assert_equal 'cerebras', settings.get('default_provider')
    settings.close

    ENV['DEEPSEEK'] = 'sk-migrate'
    reopened = Runes::Core::Settings.new(root: root)
    assert_equal 'deepseek', reopened.get('default_provider')
    assert_equal 'deepseek-flash', reopened.get('default_model')
    reopened.close
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end
