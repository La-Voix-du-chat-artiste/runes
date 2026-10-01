# Spec — Tier B (FFI backends; DELIVERED 2026-09-30)

> Status: **delivered and verified under CRuby** — the Fiddle binder drives
> the real shared libraries (libcrypto on the dev machine) through the exact
> C functions/signatures this spec lists, cross-checked against OpenSSL in
> both directions by `test/native_backend_test.rb`; the Spinel FFI file
> (`lib/runes/native/spinel_ffi.rb`) is manifest-audited and `ruby -c`
> checked, and the kernel self-check runs the whole stack via
> `spin/kernel_cruby.rb` (61 checks). The compiled-with-Spinel build remains
> pending a `spinel` binary, same caveat as Tier A.

Everything here compiles through Spinel's FFI (`ffi_lib` / `ffi_func` /
`ffi_buffer`, declarations inside a `module` body). Each backend landed behind
the Tier A facade of the same name, with CRuby parity tests, and never
changed a kernel API. B4 (time precision) is **deferred** — the wall-clock
fallback in `Compat.monotonic` is correct for TTLs, only monotonicity
weakens; `clock_gettime` over FFI lands when a compiled kernel needs it.

## Implementation map (as delivered)

| Spec item | Delivered as |
|---|---|
| B1 Ed25519 | `Runes::Security::CryptoBackend` seam + `CryptoBackends::OpenSSL` (CRuby) / `CryptoBackends::Native` (spinel); `Runes::Security::Ed25519Der` pure PKCS#8/SPKI codec (byte-identical to OpenSSL, round-trip pinned) |
| B2 HMAC + nonces | `CryptoBackend.hmac_sha256`; `Runes::Random.bytes` via `arc4random_buf`/`getrandom` FFI (CSPRNG path; PRNGPure stays ids-only) |
| B3 Settings | `Runes::Core::SettingsStore` seam: `SQLite` (CRuby, unchanged engine) / `JSONL` (pure, atomic, flock'd — the spec's chosen pick); dotenv parsing moved into `Runes::Compat.parse_dotenv` |
| Binder | `lib/runes/native.rb` (MANIFEST = single source of truth) + `native/fiddle_backend.rb` (CRuby) + `native/spinel_ffi.rb` (Spinel DSL, parse-checked + manifest-audited) |

## B1. Ed25519 identity + envelope (`Runes::Identity`, `Runes::Security::Envelope`)

FFI: **libsodium** (preferred when installed; constant-time specialist) with
**libcrypto** fallback (what the dev machine has —
`/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib`):

```
ffi_lib "sodium"
ffi_func :crypto_sign_verify_detached, [:ptr, :ptr, :size_t, :ptr], :int
ffi_func :crypto_sign_detached,        [:ptr, :ptr, :ptr, :size_t, :ptr], :int
ffi_func :crypto_sign_seed_keypair,    [:ptr, :ptr, :ptr], :int
```

libcrypto (delivered; see fiddle_backend.rb / spinel_ffi.rb for the exact
`ffi_func` rows — EVP_PKEY_new_raw_{public,private}_key with
`EVP_PKEY_ED25519 = 1087`, EVP_Digest{Verify,Sign}, EVP_PKEY_get_raw_public_key,
HMAC, EVP_sha256, SHA256):

Contract: keys cross the seam as raw 32-byte strings; `kid` fingerprints stay
SHA-256 over the SPKI DER (the pure `Ed25519Der` builder produces
byte-identical DER to OpenSSL — existing fingerprints keep verifying, pinned
by `test_fingerprint_matches_the_openssl_era`). Identity file format
(PKCS#8 PEM, 0600, atomic write) unchanged; `Identity#verify`/`#sign` public
API unchanged.

## B2. HMAC-SHA256 freshness (`Runes::Security::RPCAuth`)

One-shot `HMAC(EVP_sha256(), key, keylen, data, datalen, out32, &outlen)`;
`secure_compare` stays pure Ruby. RFC 4231 vectors 1–2 pinned in the suite.
Nonce/key randomness: `arc4random_buf` (macOS/BSD, via the always-linked
libSystem) with `getrandom(2)` loop fallback (Linux, partial-read safe).

## B3. Settings store (`Runes::Core::Settings`) — JSONL picked

Delivered per the spec's JSONL option: whole-file JSON object via
`Runes::Json`, atomic tmp+rename, corrupt-file tolerant, same
`get`/`set`/`set_if_absent` contract. CRuby keeps SQLite unchanged
(`SettingsStore::SQLite`, busy_timeout 5000 + WAL preserved). Full
`Settings` class stays out of the compiled kernel for now — it still couples
to `LLMClient` provider constants (Tier C); the store itself is kernel-clean.

## Acceptance — all met

1. Existing suite green with the CRuby wiring unchanged (675 runs, 0
   failures, three fixed seeds).
2. New parity tests: FFI result == OpenSSL result on fixed vectors, both
   directions.
3. Kernel self-check still passes with the backend active (61 checks,
   including envelope replay and the RFC 4231 vector, under Fiddle-bound
   libcrypto on CRuby).
4. No kernel API changes; facades and the CryptoBackend seam absorb
   everything.

