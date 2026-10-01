# frozen_string_literal: true

# Spinel entry point for the Runes kernel — Tier A + Tier B
# (docs/spinel-compatibility.md). Requires ONLY kernel-subset files; the
# crypto primitives bind at compile time via Spinel's FFI DSL
# (native/spinel_ffi.rb). Compile and run:
#
#   spinel spin/kernel.rb -o build/runes-kernel
#   ./build/runes-kernel selfcheck
#
# Under CRuby use spin/kernel_cruby.rb instead (Fiddle binder, same checks).

require_relative '../lib/runes/compat'
require_relative '../lib/runes/json_facade'
require_relative '../lib/runes/json_pure'
require_relative '../lib/runes/sha256_facade'
require_relative '../lib/runes/random_facade'
require_relative '../lib/runes/native'
require_relative '../lib/runes/native/spinel_ffi'
require_relative '../lib/runes/process_spawner'
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
require_relative 'selfcheck'

# Pure JSON + pure SHA-256 keep the kernel hermetic; randomness and crypto
# come from the C libraries through the FFI binder.
Runes::Json.backend = Runes::JSONPure
Runes::SHA256.backend = Runes::SHA256::Pure
Runes::Security::CryptoBackend.backend = Runes::Security::CryptoBackends::NativeBackend
# The compiled `cmd` rune spawns through posix_spawn instead of Open3.
Runes::Plugins::Cmd.command_runner = Runes::ProcessRunner::Native

# Feature-detection probe (spinel 2026.09.12): in whole-program builds the
# IO::Buffer runtime support is only linked when the analyzer sees a use on
# the main path — uses confined to required-file lambdas and singleton
# methods get missed, and every IO::Buffer.new becomes a raise. A constant
# assignment here is unreachable-for-DCE and keeps the feature linked.
IO_BUFFER_PROBE = IO::Buffer.new(8)
IO_BUFFER_PROBE.set_value(:U64, 0, 0x52554e4553) # 'RUNES'

# Nonces and key material must come from the CSPRNG, never the PRNGPure id
# generator: use the FFI random when the binder found one.
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
