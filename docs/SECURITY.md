# Security — per-agent identity, signed envelopes, broker ACLs

> Status: Phase 16 wired identity, signed envelopes and the ACL generator
> into the dispatcher. With `RUNES_REQUIRE_SIGNATURES=1` **every** inbound
> prompt path verifies before the planner sees the payload: the shared
> broadcast (`runes/prompts`), addressed delegation
> (`runes/agents/<id>/tasks`) and A2A tasks (`$a2a/v1/tasks/...`). All
> three funnel through one admission gate (`Fabric#admitted_payload`) and
> `Dispatcher#handle_prompt` refuses any envelope that did not pass it.
> Outbound delegation envelopes (and the A2A task wrapper) are signed.
> The tool-RPC request additionally carries a `{ts, nonce, mac}` freshness
> triple.

This guide covers four things:

1. the **threat model** — what this layer does and does not defend against;
2. **per-agent identity** — Ed25519 keypair lifecycle;
3. **signed envelopes** — canonical serialisation + verify-before-execute;
4. **broker ACLs** — generating a least-privilege `acl_file` and pairing it
   with broker credentials.

---

## 1. Threat model

### In scope

| Threat | Mitigation |
|---|---|
| A rogue client on the shared broker publishes a prompt as another agent | Signed envelopes on **all** inbound paths: `Envelope.verify!` rejects anything not signed by a trusted key (`:unknown_key` / `:bad_signature`), and the dispatcher refuses an unadmitted prompt even if a future subscription forgets the gate. |
| A message is modified in flight (or at rest in a proxy) | Ed25519 signature over the canonical payload bytes; a one-byte change fails with `:bad_signature`. |
| Signature ambiguity through JSON reformatting / key reordering | Canonical form: sorted keys, no whitespace, flat value types only. Unknown/unsupported values raise instead of being coerced. |
| A captured tool-RPC request is replayed | `{ts, nonce, mac}`: HMAC-SHA256 over tool id, timestamp, nonce and the request body, a ±120 s freshness window, and a bounded (300 s / 1024-entry) accepted-nonce set. |
| An agent reads or writes topics it has no business touching | `bin/runes-acl` emits a per-agent mosquitto `acl_file` with no catch-all allow; broker default is deny. The secret-bearing `runes/tools/+/request` read can be narrowed with `--tool-rpc-listener`. |
| An attacker-influenced reply topic becomes a publish target | Reply topics must start with `runes/`, contain no wildcards/`$`/empty levels, and are bounded (`Fabric#valid_reply_topic?`). |
| Credentials leak through logs / `p` / error pages | `Runes::Security::Credentials#inspect`/`#to_s` redact every value; `Identity#inspect` redacts the key. |
| A malformed key silently regenerates and breaks verification | All key loading **fails closed** with `IdentityError` / `TrustStoreError`; no auto-replacement of an unreadable key. |
| An empty trust store degrades to "trust everything" | Never: `Envelope.verify!` with no keys raises `:unknown_key`. `TrustStore.permissive` is test-only and still requires a real key. |

### Out of scope (do not assume these)

- **Transport encryption.** MQTT without TLS is plaintext; run the broker on
  localhost or put TLS in front of it. Signed envelopes prove *who* and
  *what*, not *secrecy*.
- **Replay protection for envelopes.** The tool-RPC request has a
  `{ts, nonce, mac}` freshness triple, but a *signed prompt envelope*
  itself carries no timestamp/nonce: a captured `runes/prompts` or
  delegated-task payload can still be replayed. Closing that needs the
  same freshness fields inside the signed envelope (and a seen-nonce set
  per agent). Until then, treat a signed envelope as authentic, not as
  single-use.
- **Confidentiality of prompt content.** Payloads are readable by anyone the
  broker ACL lets subscribe.
- **Broker authentication of the TLS layer, password strength, and
  per-user password storage** — mosquitto's `password_file` is your job.
- **In-process tool safety.** `Runes::Capabilities::Guard`, workspace
  confinement and WASM sandboxing are separate and unchanged.
- **Compromised agent host.** If an attacker reads
  `config/keys/<id>.pem`, they are that agent. Rotation is in §6.

### Trust assumptions

- The set of public keys in the trust store is authoritative; adding a key
  is a trust decision.
- Work distribution is the broker's job (MQTT 5 / in-process shared
  subscriptions), not a cooperative claim/lease race: the claim protocol
  was deleted in Phase 16. Any *trusted* agent can still consume prompts;
  the trust store and ACL bound who those agents are.

---

## 2. Per-agent identity

`Runes::Security::Identity` owns one Ed25519 keypair per agent.

```ruby
require_relative 'lib/runes/security/identity'

identity = Runes::Security::Identity.load_or_create(agent_id: 'runes-a')
identity.agent_id          # => "runes-a"
identity.fingerprint       # => 64-hex SHA-256 of the DER public key (the `kid`)
identity.short_fingerprint # => first 16 hex chars — display/logs only
identity.public_key_pem    # publish this to peers
identity.sign(bytes)       # => 64-byte Ed25519 signature
identity.verify(bytes, sig)
```

### Where the key comes from (precedence)

1. `RUNES_AGENT_KEY` (override the variable name with `key_env:`) holds
   either a PEM **private key** or a **path to one**. Nothing is written to
   disk in this mode — the natural fit for containers/secret stores.
2. `<dir>/<agent_id>.pem`, where `dir` defaults to
   `<project>/config/keys` (or `$RUNES_ROOT/config/keys`). The file must be
   mode `0600`; the module creates files with `0600` and an atomic
   write-temp-then-rename.
3. Otherwise a new Ed25519 keypair is generated and persisted.

```bash
# first run, per agent:
bundle exec ruby -e 'require "./lib/runes/security/identity"; \
  i = Runes::Security::Identity.load_or_create(agent_id: "runes-a"); \
  puts i.fingerprint'
ls -l config/keys/runes-a.pem   # -rw------- 
```

`config/keys/` is already covered by the repo `.gitignore` (`*.pem`).
**Never** copy a private key into a prompt, card, log or git.

### Failure modes (all fail closed)

| Situation | Result |
|---|---|
| Unreadable / missing key file when it was expected | `IdentityError` (no silent regeneration) |
| PEM that does not parse | `IdentityError` mentioning the source, never the key bytes |
| A **public** key supplied where a private key is required | `IdentityError: not a private key` |
| A non-Ed25519 key (RSA/EC) | `IdentityError` naming the actual `oid` |
| Unsafe `agent_id` (`../evil`, `a/b`, spaces, `#`, `+`) | `IdentityError` before any path is built |

`Identity#inspect` prints the agent id, algorithm and short fingerprint and
replaces the key with `[REDACTED]`.

---

## 3. Signed envelopes

`Runes::Security::Envelope` adds three fields to any JSON payload:

```json
{ "request_id": "…", "prompt": "…",
  "sig": "<base64 Ed25519>", "alg": "ed25519", "kid": "<fingerprint>" }
```

The signature covers the **canonical form of the payload without
`sig`/`alg`/`kid`**, so the metadata itself can never be smuggled into the
signed bytes.

### Canonical form

`Envelope.canonical(hash)` returns deterministic bytes:

- object keys sorted by byte order, recursively;
- no insignificant whitespace: `{"a":1,"b":{"c":"x"}}`;
- values limited to String, Integer, `true`, `false`, `nil` and nested
  Hashes. **Float, Symbol, Array, Time, … raise `EnvelopeError`** — two
  different Ruby values must never canonicalise to the same bytes.

### Sign and verify

```ruby
require_relative 'lib/runes/security/identity'
require_relative 'lib/runes/security/envelope'
require_relative 'lib/runes/security/trust_store'

# publisher
signed = Runes::Security::Envelope.sign({ 'request_id' => id, 'prompt' => text }, identity)
client.publish('runes/prompts', JSON.generate(signed))

# consumer — verify BEFORE acting on the payload
store = Runes::Security::TrustStore.load_dir('config/trust')
begin
  payload = Runes::Security::Envelope.verify!(JSON.parse(raw), store)
  run(payload['prompt'])
rescue Runes::Security::VerificationError => e
  warn "refusing unsigned/forged message: #{e.reason}" # :missing_signature|:unknown_key|:bad_signature|:malformed
end
```

Other helpers: `Envelope.signed?(hash)`, `Envelope.strip_signature(hash)`.

### Unknown/unsigned messages

Verify is **deny-by-default**: an envelope with no signature raises
`:missing_signature`; an envelope signed by a key that is not in the store
raises `:unknown_key`; a message signed by a *different* key than its `kid`
claims fails as `:bad_signature` (the store looks the `kid` up and only that
key is tried). Roll out in two phases:

1. **Observe** — log `Envelope.signed?(payload)` and verification failures
   without blocking, until every fleet member is publishing signed
   envelopes.
2. **Enforce** — reject anything that does not `verify!`.

---

## 4. Trust store

```ruby
store = Runes::Security::TrustStore.load_dir('config/trust')
store.add('runes-b', peer_public_key_pem)     # add a peer explicitly
store.key_for('runes-b')                       # => OpenSSL public key
store.trusted?('runes-b')                      # => true
store.agent_ids                                # => ["runes-b", …]
```

- `load_dir` reads every `*.pem`; the filename stem is the agent id. A
  sidecar `<stem>.id` (one line) overrides it — useful when files are named
  by host or fingerprint.
- `TrustStore.new(paths: [...])` accepts a mix of directories and files.
- Keys are indexed by **both** agent id and full SHA-256 fingerprint, so an
  envelope whose `kid` is a fingerprint resolves without extra mapping.
- A private PEM passed to `add` is reduced to its public half; the store
  never holds private material.
- **An empty store verifies nothing.** `TrustStore.permissive` (and
  `.permissive(*pems)`) exists for tests only: it relaxes `trusted?` and
  lets you index keys by fingerprint, but it never bypasses signature
  verification. It is never a default.

Example trust layout:

```
config/trust/
  runes-a.pem
  runes-b.pem
  host-07.pem
  host-07.id      # -> runes-c
```

---

## 5. Broker ACLs (`bin/runes-acl`)

Generate a mosquitto `acl_file` from the topic map:

```bash
# preview
bin/runes-acl --agent runes-a --agent runes-b

# write it
bin/runes-acl --agent runes-a --agent runes-b --out config/acl

# what exactly did I grant?
bin/runes-acl --agent runes-a --print-topics
```

Options:

| Option | Meaning |
|---|---|
| `--agent ID` | agent id, repeatable; also the mosquitto **username**. Required. |
| `--org ORG` | A2A organisation segment (default `runes`). |
| `--shared-group NAME` | shared-subscription group (default `runes-prompts`). |
| `--out FILE` | write instead of stdout. |
| `--print-topics` | list granted topics (and the denied catch-all). |
| `--allow-journal` | additionally grant `runes/_log/#` readwrite. |
| `--a2a` | grant `$a2a/v1/discovery/+/+/+` read and `$a2a/v1/discovery/<org>/+/<id>` write. |
| `--tool-rpc` | grant the tool-RPC topics. Every agent may **write** `runes/tools/+/request` and **read** `runes/tools/+/response\|error`. |
| `--tool-rpc-listener ID` | additionally let only this agent (repeatable) **read** `runes/tools/+/request` and **write** the responses. Defaults to every agent (the historical behaviour) and the generated file says so. |

### What each agent gets

```
read   runes/agents/+/card                        fleet discovery
read   runes/agents/+/status                      online/offline (LWT)
read   runes/agents/<id>/#                        own card/status/tasks/replies
read   runes/agents/<id>/tasks
read   runes/agents/<id>/tasks/+/response
read   runes/prompts                              broadcast prompt (READ ONLY)
read   $share/<group>/runes/prompts               shared-group subscribe
write  runes/agents/<id>/card | status            own retained card + LWT
write  runes/agents/+/tasks/+/response            correlated replies to peers
write  runes/prompts/+/progress | +/response      work it executes
write  runes/prompts/response                     global fan-out summary
```

The claim/lease topics (`runes/prompts/+/claim|started`,
`runes/sessions/+/claim|started`) are **not** granted: Phase 16 replaced
that protocol with broker shared subscriptions, and the ACL generator no
longer emits them.

Opt-in only: `runes/_log/#`, the `$a2a` discovery topics, the
`runes/tools/+/request|response|error` RPC topics. The request **read** is
a privilege because the payload carries `RUNES_RPC_SECRET`, so
`--tool-rpc-listener` narrows it to the agents that execute tool
requests; without that flag it stays fleet-wide and the header warns.

### Fail-closed shape

- It emits **no catch-all allow** — there is no `topic readwrite #`,
  `topic write #` or `topic read #` line. When `acl_file` is set, mosquitto
  denies every topic that is not explicitly allowed, so the generated file
  only narrows.
- `runes/prompts` itself is **read-only**. The wildcard writes are scoped to
  `runes/prompts/+/…` (a specific request's progress/response) and never to
  the broadcast topic or `runes/prompts/#`.
- An empty agent list or an unsafe id (`../x`, `bad/id`, spaces, `#`, `+`)
  exits non-zero without printing an ACL.
- `--print-topics` states the implicit deny explicitly:
  `Default deny (granted to nobody): readwrite #`.

### Mosquitto configuration

```conf
# mosquitto.conf
listener 1883 127.0.0.1
allow_anonymous false
password_file /etc/mosquitto/passwd      # usernames = agent ids
acl_file      /etc/mosquitto/runes.acl   # generated by bin/runes-acl
```

```bash
# create one password entry per agent (username = agent id)
mosquitto_passwd -b /etc/mosquitto/passwd runes-a "$(openssl rand -base64 24)"
```

Then point the agent at its credentials:

```bash
export RUNES_MQTT_USERNAME=runes-a
export RUNES_MQTT_PASSWORD='…'          # or RUNES_MQTT_TOKEN for JWT brokers
```

```ruby
opts = Runes::Security::Credentials.for_transport(settings) # {username:, password:} or {}
Runes::Security::Credentials.token(settings)                # JWT or nil
```

`Credentials#inspect`/`#to_s` redact every value; blank env vars count as
unset, so an empty export never becomes `username: ""`.

If your broker supports shared subscriptions, generate with the same
`--shared-group` the transport uses; the ACL grants both
`$share/<group>/runes/prompts` and plain `runes/prompts` so either
subscription form is covered.

---

## 6. Operations

### Onboarding a new agent

1. Generate a key on the agent host:
   `Identity.load_or_create(agent_id: 'runes-d')` **or** provision
   `RUNES_AGENT_KEY`.
2. Ship `public_key_pem` to every peer's `config/trust/runes-d.pem`
   (filename stem = agent id).
3. Add a password entry and regenerate the ACL:
   `bin/runes-acl --agent runes-a --agent runes-d --out config/acl`, then
   reload mosquitto.
4. Turn on enforcement once all publishers sign.

### Key rotation / compromise

1. Take the compromised agent off the broker ACL and restart the others
   without its public key (that alone invalidates its envelopes:
   `:unknown_key`).
2. Delete/replace its private key and re-onboard with a new fingerprint —
   fingerprints are the `kid`, so no configuration maps old keys by name.

### Verification checklist

```bash
# key hygiene
ls -l config/keys/*.pem            # expect -rw------- per agent
# trust material parses and is Ed25519
bundle exec ruby -e 'require "./lib/runes/security/trust_store"; \
  p Runes::Security::TrustStore.load_dir("config/trust").agent_ids'
# ACL has no catch-all allow
grep -E '^topic (readwrite|write) #' config/acl && echo "UNSAFE" || echo "fail-closed"
```

---

## 7. Tests

`test/security_test.rb` is hermetic (no network, `RUNES_ROOT` pointed at a
tmpdir, all secret env vars stripped): key lifecycle and 0600 perms, env-key
paths, malformed keys, sign/verify/tamper/unknown-kid/missing-sig, canonical
type rejection, key-order independence, trust-store loading and
fail-closed empty stores, credential redaction, and the generated ACL
(including "no allow-all").

```bash
bundle exec ruby -Ilib -Itest test/security_test.rb
```

## 8. Known gaps / follow-ups

- **Verification is complete for prompts, not for everything on the
  bus.** With `RUNES_REQUIRE_SIGNATURES=1` the three inbound prompt paths
  (broadcast `runes/prompts`, delegated `runes/agents/<id>/tasks`, and
  A2A `$a2a/v1/tasks/...`) verify before execution, and delegation is
  signed on the way out. Retained A2A *cards* (`record_peer_card`) are
  still accepted from any publisher: only discovery data is affected, and
  the agent id from the topic is validated against `AGENT_ID_RE`, but a
  peer can overwrite another agent's card. Tool-RPC is not
  envelope-signed; it is guarded by the shared secret plus the freshness
  triple.
- **No envelope-level replay protection.** A captured *signed prompt*
  can be replayed (work is no longer claim-leased, so a replay can run
  twice). The tool-RPC request does carry `{ts, nonce, mac}`. Adding the
  same fields to prompt envelopes is the next step.
- **`run_command` confinement is a policy, not a sandbox.** The shared
  `Runes::Security::CommandPolicy` refuses interpreters, shell
  metacharacters, command paths and escaping/unclassifiable tokens, and
  defaults to a small non-interpreter allowlist — but nothing stops a
  binary the operator explicitly allowlisted. Real confinement needs
  `sandbox-exec`/`bwrap`.
- No TLS termination guidance beyond "use a real broker on localhost";
  signed envelopes do not encrypt.
- The ACL grants every agent `write runes/prompts/+/progress|+response`
  and `write runes/agents/+/tasks/+/response`, because request ids are
  dynamic. Tighten by generating per-agent ACLs from a static agent
  registry if your topology allows it. `runes/tools/+/request` read is
  narrowed with `--tool-rpc-listener`.
- A missing *policy* file keeps the builtin baseline (documented
  allow-all for the dangerous builtins); a policy that exists but cannot
  be parsed fails closed (`Guard#policy_unreadable`).
