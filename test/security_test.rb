# frozen_string_literal: true

# Hermetic tests for the per-agent security layer:
#   lib/runes/security/identity.rb    — Ed25519 keypair lifecycle
#   lib/runes/security/envelope.rb    — canonical form + signing/verification
#   lib/runes/security/trust_store.rb — trusted peer public keys
#   lib/runes/security/credentials.rb — broker username/password/JWT
#   bin/runes-acl                     — mosquitto ACL generator
#
# No network, no real project tree: RUNES_ROOT points at a throwaway dir and
# every secret env var is stripped before the tests run.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'open3'

SECURITY_TEST_ROOT = Dir.mktmpdir('runes-security-test')
ENV['RUNES_ROOT'] = SECURITY_TEST_ROOT if ENV['RUNES_ROOT'].to_s.strip.empty?

SECRET_ENV_KEYS = %w[
  RUNES_AGENT_KEY RUNES_TEST_AGENT_KEY
  RUNES_MQTT_USERNAME RUNES_MQTT_PASSWORD RUNES_MQTT_TOKEN
].freeze
SECRET_ENV_KEYS.each { |key| ENV.delete(key) }

Minitest.after_run do
  FileUtils.remove_entry(SECURITY_TEST_ROOT) if Dir.exist?(SECURITY_TEST_ROOT)
end

require_relative '../lib/runes/security/identity'
require_relative '../lib/runes/security/envelope'
require_relative '../lib/runes/security/trust_store'
require_relative '../lib/runes/security/credentials'
require_relative '../lib/runes/security/rpc_auth'

PROJECT_ROOT = File.expand_path('..', __dir__)
ACL_BIN = File.join(PROJECT_ROOT, 'bin', 'runes-acl')

# bin/runes-acl has no .rb extension, so require_relative cannot load it;
# `load` runs the file but the CLI guard (`$PROGRAM_NAME == __FILE__`) keeps
# the argument parser from firing under the test runner.
load ACL_BIN

module SecurityTestHelpers
  def with_tmpdir
    dir = Dir.mktmpdir('runes-sec')
    yield dir
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  def identity(agent_id = 'runes-a', dir: nil)
    if dir
      Runes::Security::Identity.load_or_create(agent_id: agent_id, dir: dir)
    else
      Runes::Security::Identity.load_or_create(agent_id: agent_id, dir: @keys_dir)
    end
  end
end

# --------------------------------------------------------------------------
class IdentityTest < Minitest::Test
  include SecurityTestHelpers

  def setup
    @dir = Dir.mktmpdir('runes-keys')
    @disposable = []
  end

  def teardown
    FileUtils.remove_entry(@dir) if Dir.exist?(@dir)
    @disposable.each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
    SECRET_ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def tmpkeys
    dir = Dir.mktmpdir('runes-keys-extra')
    @disposable << dir
    dir
  end

  def test_generates_persists_and_reloads_with_stable_fingerprint
    first = Runes::Security::Identity.load_or_create(agent_id: 'runes-a', dir: @dir)
    path = File.join(@dir, 'runes-a.pem')
    assert File.file?(path), 'expected the private key to be written'
    assert_equal 0o600, File.stat(path).mode & 0o777, 'private key must be 0600'
    assert_match(/\A-----BEGIN PRIVATE KEY-----/, File.read(path))
    assert_equal 'runes-a', first.agent_id

    second = Runes::Security::Identity.load_or_create(agent_id: 'runes-a', dir: @dir)
    assert_equal first.fingerprint, second.fingerprint
    assert_equal first.public_key_pem, second.public_key_pem
    assert_equal first.private_key_pem, second.private_key_pem
    assert_match(/\A[0-9a-f]{64}\z/, first.fingerprint)
    assert_equal first.fingerprint[0, 16], first.short_fingerprint
    assert_equal first.fingerprint, first.kid
  end

  def test_sign_and_verify_round_trip
    id = Runes::Security::Identity.load_or_create(agent_id: 'runes-a', dir: @dir)
    signature = id.sign('payload bytes')
    assert_equal 64, signature.bytesize
    assert id.verify('payload bytes', signature)
    refute id.verify('payload bytez', signature)
    refute id.verify('payload bytes', nil)
  end

  def test_key_env_is_used_and_no_file_is_written
    source = Runes::Security::Identity.load_or_create(agent_id: 'runes-env', dir: @dir)
    ENV['RUNES_AGENT_KEY'] = source.private_key_pem
    dir = tmpkeys
    loaded = Runes::Security::Identity.load_or_create(agent_id: 'runes-env', dir: dir)
    assert_equal source.fingerprint, loaded.fingerprint
    refute File.exist?(File.join(dir, 'runes-env.pem')), 'env key must not be persisted'
  end

  def test_key_env_can_point_at_a_file
    source = Runes::Security::Identity.load_or_create(agent_id: 'runes-envfile', dir: @dir)
    ENV['RUNES_AGENT_KEY'] = File.join(@dir, 'runes-envfile.pem')
    loaded = Runes::Security::Identity.load_or_create(agent_id: 'runes-envfile', dir: tmpkeys)
    assert_equal source.fingerprint, loaded.fingerprint
  end

  def test_custom_key_env_name
    source = Runes::Security::Identity.load_or_create(agent_id: 'runes-custom', dir: @dir)
    ENV['RUNES_TEST_AGENT_KEY'] = source.private_key_pem
    loaded = Runes::Security::Identity.load_or_create(agent_id: 'runes-custom',
                                                      dir: tmpkeys, key_env: 'RUNES_TEST_AGENT_KEY')
    assert_equal source.fingerprint, loaded.fingerprint
  end

  def test_malformed_key_file_raises_and_does_not_regenerate
    path = File.join(@dir, 'broken.pem')
    File.write(path, 'this is not a PEM key')
    error = assert_raises(Runes::Security::IdentityError) do
      Runes::Security::Identity.load_or_create(agent_id: 'broken', dir: @dir)
    end
    assert_match(/malformed private key/, error.message)
    assert_equal 'this is not a PEM key', File.read(path), 'must not overwrite a bad key'
  end

  def test_malformed_env_key_raises
    ENV['RUNES_AGENT_KEY'] = 'not-a-pem'
    assert_raises(Runes::Security::IdentityError) do
      Runes::Security::Identity.load_or_create(agent_id: 'runes-envbad', dir: @dir)
    end
  end

  def test_public_key_is_rejected_as_a_private_key
    id = Runes::Security::Identity.load_or_create(agent_id: 'runes-pub', dir: @dir)
    File.write(File.join(@dir, 'publiconly.pem'), id.public_key_pem)
    error = assert_raises(Runes::Security::IdentityError) do
      Runes::Security::Identity.load_or_create(agent_id: 'publiconly', dir: @dir)
    end
    assert_match(/not a private key/, error.message)
  end

  def test_unsafe_agent_ids_are_rejected
    ['../evil', 'a/b', '', '.', 'has space', 'a#b', 'a+b'].each do |bad|
      assert_raises(Runes::Security::IdentityError, "expected #{bad.inspect} to be rejected") do
        Runes::Security::Identity.load_or_create(agent_id: bad, dir: @dir)
      end
    end
  end

  def test_inspect_never_leaks_the_private_key
    id = Runes::Security::Identity.load_or_create(agent_id: 'runes-a', dir: @dir)
    text = id.inspect
    refute_includes text, 'PRIVATE'
    refute_includes text, id.private_key_pem
    assert_includes text, '[REDACTED]'
    assert_includes text, id.short_fingerprint
  end

  def test_default_dir_follows_runes_root
    assert_equal File.join(ENV['RUNES_ROOT'], 'config', 'keys'), Runes::Security::Identity.default_dir
  end
end

# --------------------------------------------------------------------------
class EnvelopeTest < Minitest::Test
  include SecurityTestHelpers

  def setup
    @dir = Dir.mktmpdir('runes-env-keys')
    @identity = identity('runes-a', dir: @dir)
    @store = Runes::Security::TrustStore.new
    @store.add('runes-a', @identity.public_key_pem)
  end

  def teardown
    FileUtils.remove_entry(@dir) if Dir.exist?(@dir)
  end

  def payload
    {
      'request_id' => 'r-1',
      'prompt' => 'write hello world',
      'mode' => 'build',
      'attempt' => 2,
      'streaming' => true,
      'parent' => nil,
      'meta' => { 'z' => 1, 'a' => 'x' }
    }
  end

  def test_canonical_output
    assert_equal '{"a":1,"b":"x","c":true,"d":null}',
                 Runes::Security::Envelope.canonical('d' => nil, 'c' => true, 'b' => 'x', 'a' => 1)
    assert_equal '{"outer":{"inner":{"n":-3}}}',
                 Runes::Security::Envelope.canonical('outer' => { 'inner' => { 'n' => -3 } })
  end

  def test_canonical_rejects_ambiguous_values
    env = Runes::Security::Envelope
    assert_raises(Runes::Security::EnvelopeError) { env.canonical('x' => 1.5) }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical('x' => :symbol_value) }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical('x' => [1, 2]) }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical('x' => Time.now) }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical('x' => { 'nested' => 2.0 }) }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical('not a hash') }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical(nil) }
    assert_raises(Runes::Security::EnvelopeError) { env.canonical(42 => 'non-string key') }
    assert_raises(Runes::Security::EnvelopeError) do
      env.canonical('dup' => 1, :dup => 2)
    end
  end

  def test_sign_verify_round_trip_returns_unsigned_payload
    signed = Runes::Security::Envelope.sign(payload, @identity)
    assert_equal 'ed25519', signed['alg']
    assert_equal @identity.fingerprint, signed['kid']
    assert_kind_of String, signed['sig']
    assert Runes::Security::Envelope.signed?(signed)

    verified = Runes::Security::Envelope.verify!(signed, @store)
    assert_equal payload, verified
    %w[sig alg kid].each { |field| refute verified.key?(field) }
  end

  def test_sign_strips_a_previous_signature_and_does_not_mutate_input
    original = payload.dup
    once = Runes::Security::Envelope.sign(payload, @identity)
    twice = Runes::Security::Envelope.sign(once, @identity)
    assert_equal once['sig'], twice['sig'], 're-signing must cover the payload only'
    assert_equal original, payload, 'sign must not mutate its input'
  end

  def test_verify_is_independent_of_key_order
    signed = Runes::Security::Envelope.sign({ 'a' => 1, 'b' => { 'y' => 2, 'x' => 3 } }, @identity)
    reordered = { 'b' => { 'x' => 3, 'y' => 2 }, 'a' => 1,
                  'sig' => signed['sig'], 'alg' => signed['alg'], 'kid' => signed['kid'] }
    assert_equal Runes::Security::Envelope.canonical(reordered.reject { |k, _| %w[sig alg kid].include?(k) }),
                 Runes::Security::Envelope.canonical('a' => 1, 'b' => { 'x' => 3, 'y' => 2 })
    assert_equal({ 'a' => 1, 'b' => { 'x' => 3, 'y' => 2 } },
                 Runes::Security::Envelope.verify!(reordered, @store))
  end

  def test_tampered_payload_fails_with_bad_signature
    signed = Runes::Security::Envelope.sign(payload, @identity)
    signed['attempt'] = 3
    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, @store)
    end
    assert_equal :bad_signature, error.reason
  end

  def test_unknown_kid_fails_closed
    other = identity('runes-b', dir: @dir)
    store = Runes::Security::TrustStore.new
    store.add('runes-b', other.public_key_pem)
    signed = Runes::Security::Envelope.sign(payload, @identity) # kid = runes-a fingerprint
    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, store)
    end
    assert_equal :unknown_key, error.reason
  end

  def test_empty_store_fails_closed
    signed = Runes::Security::Envelope.sign(payload, @identity)
    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, Runes::Security::TrustStore.new)
    end
    assert_equal :unknown_key, error.reason
  end

  def test_missing_signature_fields
    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(payload, @store)
    end
    assert_equal :missing_signature, error.reason

    partial = payload.merge('sig' => 'AAAA')
    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(partial, @store)
    end
    assert_equal :missing_signature, error.reason
    refute Runes::Security::Envelope.signed?(partial)
  end

  def test_malformed_envelopes
    signed = Runes::Security::Envelope.sign(payload, @identity)

    bad_alg = signed.merge('alg' => 'rsa')
    assert_equal :malformed, assert_raises(Runes::Security::VerificationError) {
      Runes::Security::Envelope.verify!(bad_alg, @store)
    }.reason

    bad_b64 = signed.merge('sig' => '!!! not base64 !!!')
    assert_equal :malformed, assert_raises(Runes::Security::VerificationError) {
      Runes::Security::Envelope.verify!(bad_b64, @store)
    }.reason

    short_sig = signed.merge('sig' => ['short'].pack('m0'))
    assert_equal :malformed, assert_raises(Runes::Security::VerificationError) {
      Runes::Security::Envelope.verify!(short_sig, @store)
    }.reason

    assert_equal :malformed, assert_raises(Runes::Security::VerificationError) {
      Runes::Security::Envelope.verify!('not a hash', @store)
    }.reason
  end

  def test_strip_signature
    signed = Runes::Security::Envelope.sign(payload, @identity)
    stripped = Runes::Security::Envelope.strip_signature(signed)
    assert_equal payload, stripped
    refute stripped.equal?(signed)
    assert_equal({}, Runes::Security::Envelope.strip_signature(nil))
  end
end

# --------------------------------------------------------------------------
class TrustStoreTest < Minitest::Test
  include SecurityTestHelpers

  def setup
    @dir = Dir.mktmpdir('runes-trust')
    @keys = Dir.mktmpdir('runes-trust-keys')
    @identity_a = identity('runes-a', dir: @keys)
    @identity_b = identity('runes-b', dir: @keys)
  end

  def teardown
    [@dir, @keys].each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
  end

  def test_new_accepts_an_empty_path_list_and_is_empty
    store = Runes::Security::TrustStore.new
    assert store.empty?
    assert_equal 0, store.size
    assert_nil store.key_for('runes-a')
    refute store.trusted?('runes-a')
    refute store.permissive?
  end

  def test_load_dir_reads_pem_files_with_stem_as_agent_id
    File.write(File.join(@dir, 'runes-a.pem'), @identity_a.public_key_pem)
    store = Runes::Security::TrustStore.load_dir(@dir)
    assert_equal ['runes-a'], store.agent_ids
    assert store.trusted?('runes-a')
    refute store.trusted?('runes-b')
    assert_equal @identity_a.public_key_pem, store.key_for('runes-a').public_to_pem
    assert_equal @identity_a.fingerprint, Runes::Security::TrustStore.fingerprint_of(store.key_for('runes-a'))
    assert_includes store.fingerprints, @identity_a.fingerprint
  end

  def test_load_dir_honours_sidecar_id_files
    File.write(File.join(@dir, 'host-01.pem'), @identity_b.public_key_pem)
    File.write(File.join(@dir, 'host-01.id'), "runes-b\n")
    store = Runes::Security::TrustStore.load_dir(@dir)
    assert_equal ['runes-b'], store.agent_ids
    assert store.trusted?('runes-b')
  end

  def test_constructor_paths_and_instance_load_dir
    File.write(File.join(@dir, 'runes-a.pem'), @identity_a.public_key_pem)
    store = Runes::Security::TrustStore.new(paths: [@dir])
    assert store.trusted?('runes-a')

    second = Runes::Security::TrustStore.new
    second.load_dir(@dir)
    assert second.trusted?('runes-a')
  end

  def test_key_for_accepts_fingerprints
    store = Runes::Security::TrustStore.new
    store.add('runes-a', @identity_a.public_key_pem)
    assert_equal @identity_a.fingerprint,
                 Runes::Security::TrustStore.fingerprint_of(store.key_for(@identity_a.fingerprint))
  end

  def test_add_accepts_a_private_key_pem_and_reduces_it
    store = Runes::Security::TrustStore.new
    store.add('runes-a', @identity_a.private_key_pem)
    assert_equal @identity_a.public_key_pem, store.key_for('runes-a').public_to_pem
  end

  def test_no_keys_means_verification_fails_closed
    signed = Runes::Security::Envelope.sign({ 'prompt' => 'hi' }, @identity_a)
    error = assert_raises(Runes::Security::VerificationError) do
      Runes::Security::Envelope.verify!(signed, Runes::Security::TrustStore.new)
    end
    assert_equal :unknown_key, error.reason
  end

  def test_permissive_is_explicit_and_does_not_bypass_signatures
    refute Runes::Security::TrustStore.new.permissive?

    permissive = Runes::Security::TrustStore.permissive
    assert permissive.permissive?
    assert permissive.empty?
    signed = Runes::Security::Envelope.sign({ 'prompt' => 'hi' }, @identity_a)
    assert_equal :unknown_key, assert_raises(Runes::Security::VerificationError) {
      Runes::Security::Envelope.verify!(signed, permissive)
    }.reason

    # keys supplied to .permissive are indexed by fingerprint, so a real
    # signature verifies even though no agent id was registered
    indexed = Runes::Security::TrustStore.permissive(@identity_a.public_key_pem)
    assert indexed.permissive?
    assert_equal({ 'prompt' => 'hi' }, Runes::Security::Envelope.verify!(signed, indexed))
  end

  def test_malformed_pem_and_missing_dir_raise
    bad = File.join(@dir, 'garbage.pem')
    File.write(bad, 'not a key')
    assert_raises(Runes::Security::TrustStoreError) { Runes::Security::TrustStore.load_dir(@dir) }
    assert_raises(Runes::Security::TrustStoreError) do
      Runes::Security::TrustStore.load_dir(File.join(@dir, 'does-not-exist'))
    end
    assert_raises(Runes::Security::TrustStoreError) do
      Runes::Security::TrustStore.new.add('runes-x', 'nope')
    end
  end
end

# --------------------------------------------------------------------------
class CredentialsTest < Minitest::Test
  def teardown
    SECRET_ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def test_empty_when_unset
    assert_equal({}, Runes::Security::Credentials.for_transport)
    assert_nil Runes::Security::Credentials.token
    credentials = Runes::Security::Credentials.from_env
    assert credentials.empty?
    refute credentials.configured?
    assert_includes credentials.inspect, 'configured=false'
  end

  def test_transport_hash_and_token
    ENV['RUNES_MQTT_USERNAME'] = 'runes-a'
    ENV['RUNES_MQTT_PASSWORD'] = 'sup3r-s3cret'
    assert_equal({ username: 'runes-a', password: 'sup3r-s3cret' },
                 Runes::Security::Credentials.for_transport)

    ENV['RUNES_MQTT_TOKEN'] = 'eyJhbGciOiJIUzI1NiJ9.header.sig'
    assert_equal 'eyJhbGciOiJIUzI1NiJ9.header.sig', Runes::Security::Credentials.token
  end

  def test_username_only_still_returns_a_hash
    ENV['RUNES_MQTT_USERNAME'] = 'runes-a'
    assert_equal({ username: 'runes-a', password: '' }, Runes::Security::Credentials.for_transport)
  end

  def test_blank_values_count_as_unset
    ENV['RUNES_MQTT_USERNAME'] = '   '
    ENV['RUNES_MQTT_PASSWORD'] = ''
    assert_equal({}, Runes::Security::Credentials.for_transport)
  end

  def test_inspect_and_to_s_redact_every_value
    credentials = Runes::Security::Credentials.new(username: 'runes-a',
                                                   password: 'sup3r-s3cret',
                                                   token: 'jwt.payload.sig')
    [credentials.inspect, credentials.to_s].each do |text|
      refute_includes text, 'sup3r-s3cret'
      refute_includes text, 'jwt.payload.sig'
      assert_includes text, '[REDACTED]'
    end
    # accessors still return the real values for the transport
    assert_equal 'runes-a', credentials.username
    assert_equal 'sup3r-s3cret', credentials.password
    assert_equal 'jwt.payload.sig', credentials.token
    assert_equal({ username: 'runes-a', password: 'sup3r-s3cret' }, credentials.to_transport)
  end

  def test_settings_lookup_is_preferred_when_provided
    fake = Object.new
    def fake.env(key)
      { 'RUNES_MQTT_USERNAME' => 'from-settings', 'RUNES_MQTT_PASSWORD' => 'from-settings-pw' }[key]
    end
    hash = Runes::Security::Credentials.for_transport(fake)
    assert_equal 'from-settings', hash[:username]
    assert_equal 'from-settings-pw', hash[:password]

    credentials = Runes::Security::Credentials.from_env(fake)
    refute_includes credentials.inspect, 'from-settings-pw'
  end
end

# --------------------------------------------------------------------------
class AclGeneratorTest < Minitest::Test
  ACL = Runes::Security::ACL

  def test_per_agent_publish_and_read_grants
    text = ACL.new(agents: %w[runes-a runes-b]).render
    assert_includes text, "user runes-a\n"
    assert_includes text, "user runes-b\n"
    assert_includes text, 'topic write runes/agents/runes-a/card'
    assert_includes text, 'topic write runes/agents/runes-a/status'
    assert_includes text, 'topic write runes/agents/runes-b/card'
    assert_includes text, 'topic write runes/agents/runes-b/status'
    assert_includes text, 'topic read runes/agents/+/card'
    assert_includes text, 'topic read runes/agents/+/status'
    assert_includes text, 'topic read runes/agents/runes-a/#'
    assert_includes text, 'topic read runes/agents/runes-a/tasks'
    assert_includes text, 'topic write runes/agents/+/tasks/+/response'
    assert_includes text, 'topic read $share/runes-prompts/runes/prompts'
    assert_includes text, 'topic read runes/prompts'
    refute_includes text, 'runes/prompts/+/claim',
                    'the claim protocol is gone: least privilege means not granting its topics'
    assert_includes text, 'topic write runes/prompts/+/progress'
    assert_includes text, 'topic write runes/prompts/+/response'
    assert_includes text, 'topic write runes/prompts/response'
  end

  def test_never_emits_a_catch_all_allow
    text = ACL.new(agents: %w[runes-a runes-b]).render
    topic_lines = text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
    refute_includes topic_lines, 'topic readwrite #'
    refute_includes topic_lines, 'topic write #'
    refute_includes topic_lines, 'topic read #'
    refute (topic_lines.any? { |line| line.include?('readwrite #') }),
           'no catch-all allow may be emitted'
    # `runes/prompts` itself is read-only (no wildcard write on the broadcast)
    refute topic_lines.any? { |line| line.match?(%r{\Atopic (?:write|readwrite) runes/prompts\z}) },
           'the broadcast topic must never be writable as a whole'
    assert_includes text, 'Default deny'
    assert_equal 'readwrite #', ACL.new(agents: %w[runes-a]).denied_catch_all
  end

  def test_journal_is_opt_in
    refute_includes ACL.new(agents: %w[runes-a]).render, 'runes/_log'
    granted = ACL.new(agents: %w[runes-a], allow_journal: true).render
    assert_includes granted, 'topic readwrite runes/_log/#'
  end

  def test_a2a_and_tool_rpc_are_opt_in
    plain = ACL.new(agents: %w[runes-a]).render
    refute_includes plain, '$a2a/'
    refute_includes plain, 'runes/tools/'

    text = ACL.new(agents: %w[runes-a], org: 'acme', a2a: true, tool_rpc: true).render
    assert_includes text, 'topic read $a2a/v1/discovery/+/+/+'
    assert_includes text, 'topic write $a2a/v1/discovery/acme/+/runes-a'
    assert_includes text, 'topic read runes/tools/+/request'
    assert_includes text, 'topic write runes/tools/+/request'
    assert_includes text, 'topic read runes/tools/+/response'
    assert_includes text, 'topic write runes/tools/+/error'
  end

  def test_shared_group_is_configurable
    text = ACL.new(agents: %w[runes-a], shared_group: 'my-pool').render
    assert_includes text, 'topic read $share/my-pool/runes/prompts'
  end

  # S5-4: the request topic carries RUNES_RPC_SECRET, so reading it is a
  # privilege. Naming a listener narrows that read to it.
  def test_tool_rpc_request_read_is_narrowed_to_listeners
    text = ACL.new(agents: %w[runes-a runes-b], tool_rpc: true,
                   tool_rpc_listeners: %w[runes-a]).render
    agent_a = text[/# ---- agent: runes-a ----\n(.*?)(?=\n# ----|\z)/m, 1]
    agent_b = text[/# ---- agent: runes-b ----\n(.*?)(?=\n# ----|\z)/m, 1]

    assert_includes agent_a, 'topic read runes/tools/+/request'
    refute_includes agent_b, 'topic read runes/tools/+/request',
                    'a non-listener must not be able to read the secret-bearing request'
    assert_includes agent_b, 'topic write runes/tools/+/request'
    assert_includes agent_b, 'topic read runes/tools/+/response'
    refute_includes agent_b, 'topic write runes/tools/+/response'
    assert_includes agent_a, 'topic write runes/tools/+/response'

    # The default (no listener named) keeps the historical fleet-wide read
    # but says so in the generated file.
    wide = ACL.new(agents: %w[runes-a runes-b], tool_rpc: true).render
    assert_includes wide, 'tool-rpc read of runes/tools/+/request: ALL agents'
  end

  def test_tool_rpc_listener_must_be_a_known_agent
    assert_raises(ACL::ACLError) do
      ACL.new(agents: %w[runes-a], tool_rpc: true, tool_rpc_listeners: %w[ghost])
    end
  end

  def test_print_topics_lists_grants_and_the_denied_catch_all
    out = ACL.new(agents: %w[runes-a]).print_topics
    assert_includes out, 'runes-a:'
    assert_includes out, 'write     runes/agents/runes-a/card'
    assert_includes out, 'read      runes/agents/+/card'
    assert_includes out, 'Default deny (granted to nobody): readwrite #'
    assert_equal [%w[runes-a read runes/agents/+/card]],
                 ACL.new(agents: %w[runes-a]).granted_topics.select { |agent, access, topic|
                   agent == 'runes-a' && access == 'read' && topic == 'runes/agents/+/card'
                 }
  end

  def test_fails_closed_without_agents_and_on_unsafe_ids
    assert_raises(ACL::ACLError) { ACL.new(agents: []) }
    assert_raises(ACL::ACLError) { ACL.new(agents: ['../evil']) }
    assert_raises(ACL::ACLError) { ACL.new(agents: ['runes-a'], org: 'bad org') }
    assert_raises(ACL::ACLError) { ACL.new(agents: ['runes-a'], shared_group: 'x/y') }
  end

  # ---- CLI ---------------------------------------------------------------

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, ACL_BIN, *args)
  end

  def test_cli_prints_a_fail_closed_acl
    out, err, status = run_cli('--agent', 'runes-a', '--agent', 'runes-b')
    assert status.success?, "runes-acl failed: #{err}"
    assert_includes out, 'topic write runes/agents/runes-a/card'
    assert_includes out, 'topic write runes/agents/runes-b/status'
    assert_includes out, 'topic read runes/agents/+/card'
    refute_includes out, 'topic readwrite #'
    refute_includes out, 'topic write #'
  end

  def test_cli_tool_rpc_listener_narrows_the_request_read
    out, err, status = run_cli('--agent', 'runes-a', '--agent', 'runes-b',
                               '--tool-rpc', '--tool-rpc-listener', 'runes-a')
    assert status.success?, "runes-acl failed: #{err}"
    agent_b = out[/# ---- agent: runes-b ----\n(.*?)(?=\n# ----|\z)/m, 1]
    refute_includes agent_b, 'topic read runes/tools/+/request'
    assert_includes agent_b, 'topic write runes/tools/+/request'
  end

  def test_cli_out_and_print_topics_and_journal
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'acl')
      _out, err, status = run_cli('--agent', 'runes-a', '--allow-journal', '--out', path)
      assert status.success?, "runes-acl --out failed: #{err}"
      assert File.file?(path)
      assert_includes File.read(path), 'topic readwrite runes/_log/#'
    end

    out, _err, status = run_cli('--agent', 'runes-a', '--print-topics')
    assert status.success?
    assert_includes out, 'Default deny'
    refute_includes out, 'topic read'
  end

  def test_cli_requires_an_agent_and_exits_nonzero
    _out, err, status = run_cli
    refute status.success?
    assert_match(/agent/, err)

    _out, err, status = run_cli('--agent', 'bad/id')
    refute status.success?
    assert_match(/invalid agent id/, err)
  end

  def test_cli_help_succeeds
    out, _err, status = run_cli('--help')
    assert status.success?
    assert_includes out, 'Usage: bin/runes-acl'
  end
end

# --------------------------------------------------------------------------
# S5-4: freshness for the tool-RPC request
# --------------------------------------------------------------------------
class RpcAuthTest < Minitest::Test
  RPCAuth = Runes::Security::RPCAuth

  def test_mac_binds_tool_secret_timestamp_and_body
    signed = RPCAuth.sign('s3cret', 'read_file', { 'path' => 'x.txt' })
    cache = RPCAuth::NonceCache.new

    assert RPCAuth.fresh?('s3cret', 'read_file', signed, cache: cache)
    refute RPCAuth.fresh?('s3cret', 'read_file', signed, cache: cache), 'replay must be refused'
    refute RPCAuth.fresh?('s3cret', 'write_file', signed, cache: RPCAuth::NonceCache.new),
           'the tool id is MAC-bound'
    refute RPCAuth.fresh?('wrong', 'read_file', signed, cache: RPCAuth::NonceCache.new),
           'the secret is MAC-bound'
    refute RPCAuth.fresh?('s3cret', 'read_file', signed.merge('path' => 'y.txt'),
                          cache: RPCAuth::NonceCache.new),
           'the body is MAC-bound'
  end

  def test_stale_and_missing_freshness_are_refused
    cache = RPCAuth::NonceCache.new
    stale = RPCAuth.sign('s', 'ls', {}, ts: Time.now.to_i - 10_000)
    refute_nil stale['ts']
    refute RPCAuth.fresh?('s', 'ls', stale, cache: cache)
    refute RPCAuth.fresh?('s', 'ls', { 'token' => 's' }, cache: cache)
    refute RPCAuth.fresh?('s', 'ls', { 'ts' => Time.now.to_i, 'nonce' => 'n' }, cache: cache)
  end

  def test_nonce_cache_is_bounded_and_expires
    cache = RPCAuth::NonceCache.new(ttl: 300, max: 4)
    now = Time.now.to_i
    10.times { |i| assert cache.check_and_record("n#{i}", now) }

    assert_operator cache.size, :<=, 4, 'the seen-nonce set must be bounded'
    refute cache.check_and_record('n9', now), 'a recorded nonce is a replay'
    assert cache.check_and_record('after-ttl', now + 10_000), 'expired nonces must be pruned'
  end
end
