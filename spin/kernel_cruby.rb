# frozen_string_literal: true

# CRuby parity entry for the Runes kernel — identical checks to
# spin/kernel.rb, but the C libraries bind through stdlib Fiddle instead of
# Spinel's FFI DSL. This is the strongest pre-Spinel verification available:
# the self-check exercises the exact C functions (libcrypto arc4random/...)
# the compiled kernel will call.
#
#   ruby spin/kernel_cruby.rb selfcheck
#
# scripts/spinel_build.rb runs this when no `spinel` binary is on PATH.

require_relative '../lib/runes/compat'
require_relative '../lib/runes/json_facade'
require_relative '../lib/runes/json_pure'
require_relative '../lib/runes/sha256_facade'
require_relative '../lib/runes/random_facade'
require_relative '../lib/runes/native'
require_relative '../lib/runes/native/fiddle_backend'
require_relative '../lib/runes/process_spawner'
require_relative '../lib/runes/native/posix_spawn_fiddle'
require_relative '../lib/runes/security/crypto_backend'
require_relative '../lib/runes/security/crypto_backends/native'
require_relative '../lib/runes/security/ed25519_der'
require_relative '../lib/runes/security/nonce_cache'
require_relative '../lib/runes/security/envelope'
require_relative '../lib/runes/security/identity'
require_relative '../lib/runes/security/trust_store'
require_relative '../lib/runes/security/rpc_auth'
require_relative '../lib/runes/transport/topic_filter'
require_relative '../lib/runes/core/json_scan'
require_relative '../lib/runes/core/plan_parser'
require_relative '../lib/runes/security/command_policy'
require_relative '../lib/runes/request_ledger'
require_relative '../lib/runes/guard_telemetry'
require_relative '../lib/runes/capabilities/guard'
require_relative '../lib/runes/kanban'
require_relative '../lib/runes/doc_store'
require_relative '../lib/runes/index'
require_relative '../lib/runes/transport/base'
require_relative '../lib/runes/transport/in_process'
require_relative '../lib/runes/core/settings_store'
require_relative '../lib/runes/workflow_kernel'
require_relative '../lib/runes/process_runner'
require_relative 'runtime_cruby_eval'
require_relative 'selfcheck'

Runes::Json.backend = Runes::JSONPure
Runes::SHA256.backend = Runes::SHA256::Pure
Runes::Security::CryptoBackend.backend = Runes::Security::CryptoBackends::NativeBackend
Runes::Plugins::Cmd.command_runner = Runes::ProcessRunner::Native

if Runes::Native.installed?('random_bytes')
  module RunesKernelCSPRNG
    def self.bytes(n)
      Runes::Native.random_bytes(n)
    end
  end
  Runes::Random.backend = RunesKernelCSPRNG
else
  Runes::Random.backend = Runes::Random::PRNGPure
end

if ARGV[0] == 'selfcheck'
  exit(RunesKernelSelfcheck.run ? 0 : 1)
end
