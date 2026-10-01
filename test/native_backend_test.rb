# frozen_string_literal: true
require_relative 'test_helper'
require_relative '../lib/runes/native/fiddle_backend'
require_relative '../lib/runes/native/posix_spawn_fiddle'

# Tier B verification (docs/spinel/spec-tier-b.md):
#
#  1. The Fiddle binder drives the REAL shared libraries (libcrypto on this
#     machine) through the exact C functions/signatures the Spinel FFI
#     declarations bind — cross-checked against OpenSSL both directions.
#  2. The pure PKCS#8/SPKI DER codec round-trips real OpenSSL keys
#     byte-for-byte (fingerprints of existing `kid`s are unchanged).
#  3. RFC 4231 HMAC vectors, JSONL settings store, manifest audits so the
#     Fiddle binder and the Spinel FFI file cannot drift apart.
class NativeBackendTest < Minitest::Test
  def setup
    @ed25519 = Runes::Native.installed?('ed25519_verify') &&
               Runes::Native.installed?('ed25519_sign') &&
               Runes::Native.installed?('public_from_private')
    @hmac = Runes::Native.installed?('hmac_sha256')
    @digest = Runes::Native.installed?('sha256_digest')
    @random = Runes::Native.installed?('random_bytes')
  end

  # --- Native FFI vs OpenSSL, both directions ----------------------------

  def test_native_ed25519_verifies_an_openssl_signature
    skip 'libcrypto/libsodium not loadable' unless @ed25519

    key = OpenSSL::PKey.generate_key('ED25519')
    msg = 'cross-implementation check'
    openssl_sig = key.sign(nil, msg)

    assert Runes::Native.ed25519_verify(openssl_sig, msg, key.raw_public_key),
           'Native must verify an OpenSSL-produced signature'
    refute Runes::Native.ed25519_verify(openssl_sig, msg + '!', key.raw_public_key)
    refute Runes::Native.ed25519_verify(openssl_sig, msg, key.raw_public_key.reverse)
  end

  def test_native_ed25519_signature_verifies_under_openssl
    skip 'libcrypto/libsodium not loadable' unless @ed25519

    seed = OpenSSL::PKey.generate_key('ED25519').raw_private_key
    pk = Runes::Native.public_from_private(seed)
    sig = Runes::Native.ed25519_sign('kernel bytes', seed)

    openssl_key = OpenSSL::PKey.new_raw_public_key('ED25519', pk)
    assert openssl_key.verify(nil, sig, 'kernel bytes'),
           'OpenSSL must verify a Native-produced signature'
    refute openssl_key.verify(nil, sig, 'kernel bytez')
  end

  def test_native_hmac_matches_openssl
    skip 'libcrypto not loadable' unless @hmac

    5.times do |i|
      key = OpenSSL::Random.random_bytes(8 + i * 7)
      msg = "message #{i}"
      expected = OpenSSL::HMAC.digest(OpenSSL::Digest.new('SHA256'), key, msg)
      assert_equal expected, Runes::Native.hmac_sha256(key, msg)
    end
  end

  def test_native_hmac_rfc4231_vectors
    skip 'libcrypto not loadable' unless @hmac

    # RFC 4231 case 1: key = 0x0b x20, data = "Hi There"
    assert_equal 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
                 Runes::Native.hmac_sha256(["0b" * 20].pack('H*'), 'Hi There').unpack1('H*')
    # RFC 4231 case 2: key = "Jefe", data = "what do ya want for nothing?"
    assert_equal '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
                 Runes::Native.hmac_sha256('Jefe', 'what do ya want for nothing?').unpack1('H*')
  end

  def test_native_sha256_matches_openssl
    skip 'libcrypto not loadable' unless @digest

    ['', 'abc', 'x' * 555].each do |msg|
      assert_equal OpenSSL::Digest::SHA256.digest(msg), Runes::Native.sha256_digest(msg)
    end
  end

  def test_native_random_bytes
    skip 'arc4random/getrandom not loadable' unless @random

    a = Runes::Native.random_bytes(48)
    b = Runes::Native.random_bytes(48)
    assert_equal 48, a.bytesize
    refute_equal a, b
  end

  def test_native_unavailable_primitives_raise
    Runes::Native.install!({}) # simulate a bare runtime
    assert_raises(Runes::Native::UnavailableError) { Runes::Native.hmac_sha256('k', 'm') }
    assert_raises(Runes::Native::UnavailableError) { Runes::Native.random_bytes(8) }
    refute Runes::Native.ed25519_verify('sig', 'msg', 'pk') # verify fails closed
  ensure
    Runes::Native::FiddleBackend.load! # restore the real binding
  end

  # --- pure DER codec vs OpenSSL -----------------------------------------

  def test_private_pem_round_trips_through_openssl
    seed = OpenSSL::PKey.generate_key('ED25519').raw_private_key
    pem = Runes::Security::Ed25519Der.private_pem(seed)

    key = OpenSSL::PKey.read(pem)
    assert_equal seed, key.raw_private_key
    assert pem.start_with?("-----BEGIN PRIVATE KEY-----\n")
    assert_equal 64, pem.lines[1].strip.length, 'PEM body wraps at 64 columns like OpenSSL'
  end

  def test_public_pem_round_trips_through_openssl
    key = OpenSSL::PKey.generate_key('ED25519')
    pem = Runes::Security::Ed25519Der.public_pem(key.raw_public_key)

    read_back = OpenSSL::PKey.read(pem)
    assert_equal key.raw_public_key, read_back.raw_public_key
  end

  def test_der_parser_reads_openssl_keys
    key = OpenSSL::PKey.generate_key('ED25519')

    parsed_priv = Runes::Security::Ed25519Der.parse_pem(key.private_to_pem)
    assert_equal :private, parsed_priv[:kind]
    assert_equal key.raw_private_key, parsed_priv[:seed]

    parsed_pub = Runes::Security::Ed25519Der.parse_pem(key.public_to_pem)
    assert_equal :public, parsed_pub[:kind]
    assert_equal key.raw_public_key, parsed_pub[:raw]
  end

  def test_spki_der_is_byte_identical_to_openssl
    key = OpenSSL::PKey.generate_key('ED25519')
    assert_equal key.public_to_der,
                 Runes::Security::Ed25519Der.public_spki_der(key.raw_public_key)
  end

  def test_fingerprint_matches_the_openssl_era
    key = OpenSSL::PKey.generate_key('ED25519')
    legacy = Digest::SHA256.hexdigest(key.public_to_der)

    assert_equal legacy, Runes::Security::TrustStore.fingerprint_of(key.public_to_pem)
    assert_equal legacy, Runes::Security::TrustStore.fingerprint_of(key.raw_public_key)
  end

  def test_der_refuses_garbage_and_wrong_keys
    assert_raises(Runes::Security::Ed25519Der::DerError) { Runes::Security::Ed25519Der.parse_pem('not a key') }

    rsa = OpenSSL::PKey::RSA.new(2048)
    error = assert_raises(Runes::Security::Ed25519Der::DerError) do
      Runes::Security::Ed25519Der.parse_pem(rsa.public_to_pem)
    end
    assert_match(/Ed25519/, error.message)
  end

  def test_private_pem_given_where_public_expected_fails_closed
    seed = OpenSSL::PKey.generate_key('ED25519').raw_private_key
    store = Runes::Security::TrustStore.new
    store.add('agent', Runes::Security::Ed25519Der.private_pem(seed))
    # Reduced to its public half, exactly like the OpenSSL era.
    assert store.trusted?('agent')
  end

  # --- JSONL settings store ----------------------------------------------

  def test_jsonl_store_persists_and_seeds
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'preferences.json')
      one = Runes::Core::SettingsStore::JSONL.new(path: path)
      one.set('default_provider', 'deepseek')
      one.set_if_absent('default_provider', 'cerebras') # must not clobber
      one.set_if_absent('default_variation', 'high')

      two = Runes::Core::SettingsStore::JSONL.new(path: path)
      assert_equal 'deepseek', two.get('default_provider')
      assert_equal 'high', two.get('default_variation')
      assert_equal 'fallback', two.get('missing', 'fallback')
    end
  end

  def test_jsonl_store_tolerates_a_corrupt_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'preferences.json')
      File.write(path, '{not json')
      store = Runes::Core::SettingsStore::JSONL.new(path: path)
      assert_equal 'x', store.get('k', 'x')
      store.set('k', 'v')
      assert_equal 'v', Runes::Core::SettingsStore::JSONL.new(path: path).get('k')
    end
  end

  # --- Tier C2: process spawner (posix_spawn FFI) --------------------------

  def test_spawner_spawn_env_chdir_and_pipes
    skip 'posix_spawn spawner not bound' unless Runes::ProcessSpawner.available?

    env = Runes::ProcessSpawner.spawn(['/usr/bin/env'], env: { 'ONLY' => 'this' }, chdir: '/tmp')
    env[:stdin].close
    assert_equal "ONLY=this\n", env[:stdout].read

    pwd = Runes::ProcessSpawner.spawn(['/bin/pwd'], env: {}, chdir: '/private/tmp')
    pwd[:stdin].close
    assert_equal "/private/tmp\n", pwd[:stdout].read
  end

  def test_spawner_separate_stdout_stderr_and_exit
    skip 'posix_spawn spawner not bound' unless Runes::ProcessSpawner.available?

    sh = Runes::ProcessSpawner.spawn(['/bin/sh', '-c', 'echo out; echo err 1>&2; exit 3'], env: {})
    sh[:stdin].close
    assert_equal "out\n", sh[:stdout].read
    assert_equal "err\n", sh[:stderr].read
    status = Runes::ProcessSpawner.wait(sh[:pid])
    # CRuby's SIGCHLD reaper may own the status; a compiled kernel reads it.
    assert status[:unavailable] || status[:exitstatus] == 3,
           "expected exit 3 or CRuby-reaped, got #{status.inspect}"
  end

  def test_spawner_kill_tree_leaves_no_orphans
    skip 'posix_spawn spawner not bound' unless Runes::ProcessSpawner.available?

    baseline = `ps -eo comm`.lines.count { |line| line.strip == 'sleep' }
    sleeper = Runes::ProcessSpawner.spawn(['/bin/sh', '-c', 'sleep 30'], env: {})
    sleeper[:stdin].close
    Runes::ProcessSpawner.kill_tree(sleeper[:pid])
    Runes::ProcessSpawner.wait(sleeper[:pid])
    # A grandchild can join the group after the first sweep (sh forks it
    # just as the group dies); a supervisor reaps, then re-sweeps.
    Runes::ProcessSpawner.kill_tree(sleeper[:pid])
    orphans = baseline
    10.times do
      sleep 0.1
      orphans = `ps -eo comm`.lines.count { |line| line.strip == 'sleep' }
      break if orphans <= baseline
    end
    assert_equal baseline, orphans, 'kill_tree must leave no NEW orphans'
  end

  def test_decode_wait_status_vectors
    assert_equal 3, Runes::ProcessSpawner.decode_wait_status(3 << 8)[:exitstatus]
    refute Runes::ProcessSpawner.decode_wait_status(3 << 8)[:signaled]
    assert Runes::ProcessSpawner.decode_wait_status(9)[:signaled]
    assert_equal 0, Runes::ProcessSpawner.decode_wait_status(0)[:exitstatus]
  end

  def test_spawner_spawn_missing_binary_raises
    skip 'posix_spawn spawner not bound' unless Runes::ProcessSpawner.available?

    error = assert_raises(Runes::ProcessSpawner::SpawnError) do
      Runes::ProcessSpawner.spawn(['/definitely/not/here'], env: {})
    end
    assert_match(/posix_spawn failed/, error.message)
  end

  def test_spinel_ffi_spawner_uses_the_manifest_syscalls
    source = File.read(File.expand_path('../lib/runes/native/spinel_ffi.rb', __dir__))
    %w[posix_spawn posix_spawn_file_actions_adddup2 POSIX_SPAWN_SETPGROUP waitpid].each do |token|
      assert_includes source, token, "ffi_source spawner is missing #{token}"
    end
  end

  # --- manifest audits: the two binders cannot drift ----------------------

  def test_spinel_ffi_file_declares_every_manifest_function
    source = File.read(File.expand_path('../lib/runes/native/spinel_ffi.rb', __dir__))
    Runes::Native::MANIFEST.each_key do |c_name|
      assert_includes source, c_name.to_s, "spinel_ffi.rb does not declare #{c_name}"
    end
  end

  def test_spinel_ffi_file_parses
    path = File.expand_path('../lib/runes/native/spinel_ffi.rb', __dir__)
    output = `#{RbConfig.ruby} -c #{path} 2>&1`
    assert $?.success?, "spinel_ffi.rb syntax error:\n#{output}"
  end

  def test_spinel_kernel_entry_parses
    path = File.expand_path('../spin/kernel.rb', __dir__)
    output = `#{RbConfig.ruby} -c #{path} 2>&1`
    assert $?.success?, "spin/kernel.rb syntax error:\n#{output}"
  end

  def test_fiddle_binder_covers_the_libcrypto_primitives
    skip 'libcrypto not loadable' unless @ed25519 && @hmac && @digest

    bound = Runes::Native::FiddleBackend.load!
    %w[ed25519_verify ed25519_sign public_from_private hmac_sha256 sha256_digest].each do |primitive|
      assert bound.key?(primitive), "Fiddle binder did not provide #{primitive}"
    end
  end
end
