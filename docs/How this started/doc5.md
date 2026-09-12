# Runes — Code Review, Round 5: Flaws & Proposed Enhancements

Scope: the whole repository at 0.3.0 + Phase 17 — `lib/` (12 146 lines /
55 files), the hermetic suite (34 files), the `bin/` CLIs, the Rails
observatory (`runes_observer/`, 1 025 app lines), and the new
Roast-compatible workflow/rune layer (~3 300 lines).

Method: adversarial reading plus runtime reproduction. Every finding below
carries the command that produced it or the exact call chain; nothing is
reported from reading alone unless it is marked *unverified*. Five parallel
deep audits were run over the transport, the workflow engine, security, the
observatory and the test/documentation surface; their findings are merged in
Part 2 with the same format.

**Headline.** Four findings change how the project should be read, and all
four were verified by reproduction. The MQTT 5 transport cannot recover from a
lost connection and reports itself healthy (T5-1). The workflow `cmd` rune
executes through a shell, so a workflow *argument* is remote code execution
(W5-1). The observatory's fleet view is broken for live traffic: one invalid
byte wedges ingest into a reconnect/duplicate loop (O5-1) and only 1 row in 4 is
attributed to an agent, because the claim/started vocabulary it relies on was
deleted in Phase 16 (O5-5, from X5-1). And the test suite is not hermetic — 15
tests dial a real broker on port 1883 (D5-1), which is why the other three
survived. `RUNES_REQUIRE_SIGNATURES=1` is enforced on the
broadcast prompt path only, so an unsigned payload on the delegated or A2A
task topics still reaches the planner (S5-1); and `run_command` confinement
is bypassable by default, so a planner step can read and write outside the
workspace (S5-2) — the S4-2 finding from round 4 is *not* fixed. A corrupt
`config/policy.json` also fails **open** on exactly the dangerous builtins
(S5-3). The rest of the round is drift at the seams: a protocol deleted in
Phase 16 still lives in the observatory and its demo, agent identity is
normalized on one channel and not the other, three topic matchers disagree
with each other and with MQTT 3.1.1, and the plugin registry's reset path is
not atomic. The Phase 17 layer itself is in good shape — packaging is real,
the CLI works from an installed gem, and the Roast-compatible example is
genuinely byte-identical.

---

## Part 1 — Cross-cutting findings

### X5-1 (medium) The observatory still models the protocol Phase 16 deleted, and its demo manufactures it

Phase 16 ("P0.2 — the consensus is gone") removed the claim/lease protocol:
work is now distributed by MQTT 5 shared subscriptions and nothing publishes
a claim or a lease. The deletion stopped at the `lib/` boundary.

Evidence — no publisher exists any more:

```
$ grep -rn "runes/sessions" lib bin          # → no matches
$ grep -rhoE '"(runes/[^"]*)"' lib/runes | sort -u
  runes/prompts                            ← the only prompt lifecycle topics
  runes/prompts/#{request_id}/progress        published today are /progress
  runes/prompts/#{env[:request_id]}/response  and /response
  runes/prompts/response
  ...
```

…but the observer still ships the vocabulary, and its demo invents the
traffic:

- `runes_observer/app/services/packet_classifier.rb:33-34` — `SESSION_CLAIM`,
  `SESSION_STARTED` patterns (`PROMPT_CLAIM`/`PROMPT_STARTED` above them too).
- `runes_observer/app/models/packet.rb` — `KINDS` advertises
  `session_claim`, `session_started` (and `claim`, `started`); `lease_id`
  column, `for_lease` scope, `correlation_key` lease branch,
  `request_scoped?` entries.
- `runes_observer/db/schema.rb` — `lease_id` column plus two indexes.
- `interactions_controller.rb:7`, `agents_controller.rb:43-47` — lease
  grouping and lease lookups.
- Views: `interactions/show.html.erb:6` ("session lease"),
  `agents/show.html.erb:60-71`, `packets/_packet.html.erb:26-27`,
  `packets/index.html.erb:23` (a filter labelled "Request / lease").
- `demo_fabric.rb:97-98` publishes `runes/prompts/<req>/claim` and `/started`;
  `demo_fabric.rb:125-126` publishes `runes/sessions/<lease>/claim` and
  `/started`. **Four of the fifteen topics the demo emits cannot be produced
  by the harness at all.**
- The fiction is pinned by tests, so removing it will look like a
  regression: `packet_classifier_test.rb:62,67`,
  `interactions_controller_test.rb:19`.

Impact: a new user runs the demo (the app's de-facto documentation) and
learns a protocol that no longer exists; the UI offers filters, badges and a
grouping path that can never match live traffic; and the dead model is
locked in by tests, so the cost of removing it grows every round.

Fix: delete the dead vocabulary — classifier patterns, `KINDS` entries, the
`lease_id` column/scopes/indexes (one migration), the controller and view
branches, and the demo's claim/lease emissions. ~1 hour, mechanical. If
leases are planned to return, document that and stop shipping them as demo
data.

### X5-2 (medium-low) Agent ids are normalized for A2A but never validated at startup — one agent becomes two rows, or none

`Runes::A2A.segment` (`lib/runes/a2a.rb:62`) rewrites anything outside
`[A-Za-z0-9_.-]` to `-` before it builds an A2A topic, while the legacy card
topic uses the raw id. The dispatcher sets
`@agent_id = agent_id || "runes-#{hostname}-#{pid}"`
(`lib/runes/core/dispatcher.rb:126`) with **no validation**, even though
`AGENT_ID_RE` sits right there (`:89`) and is only used at
`lib/runes/agent/fabric.rb:232` to validate a delegation *reply* topic.
`Runes::Security::Identity` **does** validate ids and raises
(`lib/runes/security/identity.rb:136`) — the harness contradicts itself.

Reproduction:

```ruby
require_relative "lib/runes/a2a"
require_relative "runes_observer/app/services/packet_classifier"
raw = "runes:studio4012"
Runes::A2A.agent_id_from_discovery(Runes::A2A.discovery_topic(org: "runes", unit: "dev", agent_id: raw))
# => "runes-studio4012"
PacketClassifier.call(topic: "runes/agents/#{raw}/card", payload: "{}").agent_id
# => "runes:studio4012"          two Agent rows for one agent
```

With a `/` in the id the legacy card topic becomes
`runes/agents/runes/studio4012/card`, which matches **no** classifier rule
(`AGENT_CARD` ends in `([^/]+)/card`), so the agent is invisible on the
legacy channel and appears only mangled via A2A.

Impact: silent identity splitting in the fleet view; an agent that simply
never shows up; topic-grammar ambiguity for ids containing `/`.

Fix: validate `@agent_id` against `AGENT_ID_RE` when the dispatcher is
constructed and fail fast (3 lines, consistent with `Identity`). Percent-
encoding in `segment` is the alternative but validation is smaller and more
honest.

### X5-3 (medium-low) `Runes::Plugin.reset!` is not atomic and raises permanently after a shadowed declaration

`plugin` appends the class to `Plugin.declared` *before* calling `register`
(`lib/runes/plugin.rb`), and `reset!` re-registers every declared class with
`replace: false`. If two declared classes hold the same name — reachable with
`plugin :name, replace: true` — the second re-registration aborts the loop.

Reproduction:

```ruby
require "runes/plugin"
A = Class.new(Runes::Plugin); A.plugin :shared
B = Class.new(Runes::Plugin); B.plugin :shared, replace: true
C = Class.new(Runes::Plugin); C.plugin :later
Runes::Plugin.reset!
```

Observed:

```
reset! RAISED: Runes::Plugin::DefinitionError: plugin rune:shared is already registered by A
registry left as: [:shared]      # C, declared after the collision, was never re-registered
```

Impact: `test/plugin_test.rb` calls `reset!` in teardown, and any
`replace: true` re-registration (a test double, an embedder hot-swapping a
rune) makes every later `reset!` raise while leaving the registry partially
rebuilt — built-in runes can disappear. The workflow path self-heals because
`Workflow#prepare!` calls `register_builtin_runes!`; anything using `reset!`
alone does not.

Fix: append to `declared` only after `register` succeeds, and re-declare with
`replace: true` (or collect per-class failures) so one bad entry cannot abort
the rebuild.

### X5-4 (medium) Three topic matchers disagree with each other and with MQTT 3.1.1

`lib/runes/transport/topic_filter.rb` (used by the in-process hub),
`lib/runes/mqtt/broker.rb:647` (the embedded broker) and
`lib/runes/capabilities/guard.rb:178` (its own regex compiler) are three
independent implementations of the same idea. Measured:

| filter | topic | transport | broker | guard | MQTT 3.1.1 |
| --- | --- | --- | --- | --- | --- |
| `a/#/b` | `a/x/b` | true | true | false | invalid filter |
| `a/` | `a` | false | false | **true** | false |
| `a/` | `a/` | true | true | **false** | true |
| `a/+` | `a/` | true | true | **false** | true |
| `#` | `$a2a/v1/x` | **true** | **true** | **true** | **false** |
| `+/card` | `$a2a/card` | **true** | **true** | **true** | **false** |

Three consequences, all verified:

1. **The guard's trailing-slash semantics are inverted.** The guard splits
   with `split("/")`, which drops trailing empty levels, so a policy rule
   `runes/prompts/` *allows* publishing to the different topic
   `runes/prompts` and *denies* the topic it literally names:

   ```
   guard.allowed?("t", :mqtt_publish, "runes/prompts")   # => true
   guard.allowed?("t", :mqtt_publish, "runes/prompts/")  # => false
   ```

   That is a fail-open on a topic the operator did not name, from what looks
   like a typo.

2. **The in-process hub does not behave like a broker.** MQTT 3.1.1 §4.7.2
   forbids a filter that starts with a wildcard from matching a topic that
   starts with `$`; all three implementations match anyway:

   ```
   $ ruby -Ilib -e 'require "runes/transport"; t = Runes::Transport.build(kind: :inproc); t.connect
     got = []; t.subscribe("#") { |m| got << m.topic }
     t.publish("runes/prompts", "a"); t.publish("$a2a/v1/discovery/x/y/z", "b"); sleep 0.3
     p got'
   # => ["runes/prompts", "$a2a/v1/discovery/x/y/z"]
   ```

   Mosquitto delivers only the first. Every test in the suite that asserts
   wildcard behaviour runs against this hub, so a filter can pass in CI and
   drop traffic in production — the seam leaks exactly where it claims to
   unify.

3. **`#` in the middle of a filter** (invalid per spec) is a wildcard on the
   wire and in the hub, but literal in the guard — so ACL generation and
   enforcement can disagree.

Fix: one implementation. Make `TopicFilter` spec-correct — leading wildcards
never match `$`-topics, a mid-filter `#` is invalid (no match, or rejected at
SUBSCRIBE), empty levels preserved — and have the guard, the broker and every
adapter call it. Add the matrix above as a test.

---

## Part 2 — Deep audits

Five parallel audits were run; findings are merged here with the same
severity/evidence/fix format. Identifiers are namespaced by area:
`W5-*` workflow & runes, `T5-*` transport/A2A/MCP, `S5-*` security &
dispatcher, `O5-*` observatory, `D5-*` tests & documentation.

### S5 — Security, capabilities and dispatch

Verification status is marked per item: **[re-verified]** means I reproduced
it myself after the auditor reported it; **[auditor]** means the auditor's
reproduction is quoted but I have not re-run it.

#### S5-1 (high) `RUNES_REQUIRE_SIGNATURES=1` does not cover delegated or A2A task topics **[re-verified]**

`lib/runes/agent/fabric.rb` verifies signatures in exactly one handler:

```ruby
def handle_incoming_broadcast(message)                      # :183
  return if @require_signatures && verify_signed!(message, reply_topic).nil?
```

`handle_delegated_task` (`:223`, subscribed at `:100` on
`runes/agents/<id>/tasks`) and `handle_a2a_task` (`:250`, subscribed at
`:159` on `A2A.task_wildcard`) both call `handle_prompt` with **no**
`@require_signatures` check. A2A is on unless explicitly disabled, so the
default daemon subscribes that wildcard.

The auditor ran all three paths with signing required and a populated trust
dir: the broadcast was refused, while the delegated and A2A payloads reached
the planner (log `[Dispatcher] Asking planner LLM`) and published progress,
response and journal traffic. This directly contradicts the documented
guarantee — `README.md:428-431` ("**every** inbound envelope must verify …
missing / unknown / bad signatures are refused and answered *before* the
planner sees them") and `docs/SECURITY.md:25` (the rogue-prompt threat is
"mitigated" by signed envelopes).

Fix: run the same `verify_signed!` gate in both handlers before
`handle_prompt`, answer refusals on the reply topic, and add negative tests
for the delegated and A2A paths (`fabric_test.rb:206` only exercises the
broadcast). Separately, `handle_incoming_broadcast` discards
`verify_signed!`'s return value and executes the pre-verification parse —
bind the verified envelope to the executed one.

#### S5-2 (high) `run_command` is still not confined — S4-2 is not fixed **[re-verified]**

`command_path_violation?` (`lib/runes/core/dispatcher.rb:1364-1386`) rejects
only tokens that *start* with `~`/`/` or contain `..`; anything else
containing `/` is passed to `safe_path`, which happily treats arbitrary text
as a relative filename. `command_allowlisted?` (`:1399`) is a no-op when
`RUNES_CMD_ALLOWLIST` is unset, and the guard baseline is `exec => ['#']`
(`guard.rb:29-33`) — i.e. allow-all.

Reproduced by me, from the repository root:

```
violation=nil              ruby -e %q{File.read("/etc/passwd")}
violation=nil              curl -o/tmp/out http://x
safe_path('File.write("/x","y")') => ".../probe_ws/File.write(\"/x\",\"y\")"   # a "path" inside the workspace
run_in_workspace(ruby -e 'File.write("<repo>/tmp/escaped_proof.txt","pwned")') => exit=0
ESCAPED (file outside the harness workspace exists): true
```

`run_in_workspace` executes through `sh -c`, so token scanning is the only
barrier and it does not see paths inside an interpreter payload or attached
to an option (`-o/tmp/out`). The same flawed scan is duplicated in
`bin/runes-mcp:281-292` (with `sh -c`), so any fix must be applied twice or
extracted.

The regression test that was supposed to pin this
(`test/fourth_audit_test.rb:225-232`) passes on the bypassable
implementation because it only tests literal `..`/`~`/`/` tokens.

Fix: one shared command-policy checker for the dispatcher and `bin/runes-mcp`;
default to a small non-interpreter allowlist; refuse a first token that is an
interpreter (`ruby`, `sh`, `python`, `perl`, …) unless explicitly allowed;
reject attached-option paths; and treat an unclassifiable token as a
violation rather than as a relative path. Real confinement needs
`sandbox-exec`/`bwrap` — token scanning cannot bound an interpreter.

#### S5-3 (medium) A malformed policy file fails **open** for the dangerous builtins **[re-verified]**

`guard.rb:37-49` merges `BUILTIN_BASELINE` before `load_policy`, and
`load_policy` (`:150-157`) rescues a parse failure, warns "using
default-deny", and returns `{}` — so nothing revokes the baseline.

With `config/policy.json` containing invalid JSON:

```
write_file  / fs_write / anything.txt => true
read_file   / fs_read  / /etc/passwd  => true
run_command / exec     / rm -rf ..    => true
unknown_tool/ execute  / x            => false
```

One JSON typo in a narrowing policy leaves `write_file`/`read_file`/
`run_command` allow-all, under a message that claims the opposite. Fix: load
the policy first; if an explicitly configured policy cannot be read or
parsed, either drop the baseline or refuse to boot; correct the warning text.

#### S5-4 (medium) No replay protection, and the shared RPC secret is readable fleet-wide **[auditor]**

`dispatcher.rb:1187-1198` compares a static token and nothing carries
freshness — `grep -rniE "nonce|replay|expir|timestamp" lib/runes/security
lib/runes/core/dispatcher.rb` is empty — so a captured RPC request or signed
envelope replays indefinitely. Worse, `bin/runes-acl:139` grants
`topic read runes/tools/+/request` to **every** agent under `--tool-rpc`,
`fabric.rb:167` subscribes that wildcard, and the token travels in the
payload: any fleet member can read the secret and forge requests.
Fix: per-agent RPC topics, a `{ts, nonce}` MAC with a bounded seen-nonce
set, and no fleet-wide read of the request topic.

#### S5-5 (low) Attacker-controlled `response_topic` is used as a publish target **[auditor]**

`fabric.rb:258-264` publishes to `message.response_topic` unchecked (and
`:186-187` reuses it as the reply topic); neither `transport/base.rb:21` nor
the adapters validate it. A publisher can therefore make a victim publish on
arbitrary topics — enough to forge another agent's card or status.
Fix: require a `runes/` prefix and reject wildcards and `$`-topics.

#### S5-6 (low) Reply reflection and A2A card spoofing **[auditor]**

`fabric.rb:241-245` republishes an arbitrary task-reply payload onto the
global `runes/prompts/response` topic, and `fabric.rb:269-286` accepts
retained A2A cards from any publisher (the agent id comes from the topic), so
a peer can overwrite another agent's card. Discovery-only impact.

#### S5-7 (low) A null byte in a `write_file` path kills the worker **[auditor]**

`safe_path` (`dispatcher.rb:1316-1334`) calls `File.expand_path`, which
raises `ArgumentError` on `"a\0b"`; `handle_tool_request` (`:1148-1182`) has
no rescue, so the tool worker dies with no error reply. The planner path is
saved by `execute_step`'s rescue. Fix: reject null bytes in `safe_path`
and/or wrap `execute_builtin`.

#### S5-8 (low) Secrets at rest **[auditor; liveness unverified]**

`config/.env` is mode `0644` and holds a `DEEPSEEK` value matching the
provider-key shape. It **is** git-ignored (`.gitignore` lists `config/.env`)
and there is no `.git` repository, so the S4-3 exposure has not materialised.
`log/journal.jsonl` is `0644` (sentinel entry only; the key is not in it).
Fix: `chmod 600` both, `0700` on `log/`.

#### Verified sound (security) **[auditor]**

Tool RPC is genuinely closed by default (no subscription without
`RUNES_TOOL_RPC`; unauthenticated requests execute nothing and answer
`Error: unauthorized`); envelope canonicalization is sound (sorted nested
keys, no floats/symbols/arrays, duplicate-key detection, fail-closed on an
empty trust store, unknown kid or tamper); the guard's wildcard semantics are
correct apart from the malformed-file case; the `const_set` mirrors from the
dispatcher split are equal to the originals at runtime; session/peer/notice/
deny-log maps are bounded; the journal holds an exclusive `flock` across
rotate-check-append; no API key is logged and the child environment is
scrubbed.

### T5 — Transport, MQTT 5, A2A, MCP

This is the most serious section of the round. The MQTT 5 adapter is the
production path — shared subscriptions are the mechanism the whole design
rests on — and **none of its socket lifecycle is covered by the suite**:
`test/mqtt5_codec_test.rb` never calls `#connect` (every instance points at
`example.invalid`). Everything below was found by driving the real adapter
against mosquitto 2.1.2 and against a purpose-built fake broker.

#### T5-1 (critical) No reconnect and no re-subscribe — a lost connection is a silent black hole **[re-verified]**

```
$ grep -rniE "reconnect|backoff|retry_connect" lib/runes/transport*.rb lib/runes/transport/
(nothing)
$ grep -n "\.connect\b" lib/runes/core/dispatcher.rb
183:        @transport.connect unless @transport.connected?
```

`read_loop`'s `ensure` (`mqtt5.rb:699-732`) only sets `@connected = false`;
nothing retries and no disconnect hook exists, so the dispatcher — which
connects exactly once — never learns. The auditor's live reproduction: with a
subscriber on `runes/audit/N/t`, closing the socket leaves
`connected? == false`; calling `#connect` again reports `connected? == true`
and `subscriptions == ["runes/audit/341/t"]`, but the broker has no
subscription because `#connect` does not re-SUBSCRIBE. The next publish is
never delivered, and every health signal says "fine".

Impact: a broker restart, a network blip or a keepalive failure silently turns
an agent deaf for the rest of its life — and it looks exactly like "no work
arrived". For a fleet harness that is the worst available failure mode.

Fix: in `read_loop`'s `ensure`, when the disconnect was not deliberate, run an
exponential-backoff reconnect (1 s → 30 s, jittered) that re-sends CONNECT and
re-SUBSCRIBEs every entry in `@subscriptions` (registration happens before
SUBSCRIBE, so that list is the source of truth). Add a `health`/`on_disconnect`
hook so the dispatcher can surface it, and a `FakeBroker` test that drops the
socket and asserts re-delivery.

#### T5-2 (high) Keepalive never verifies PINGRESP **[re-verified]**

```
$ grep -n "PINGRESP" lib/runes/transport/mqtt5.rb
749:        when 13 then nil # PINGRESP: liveness is already covered by @last_write
```

`@last_write` is set by *our* writes, so a half-open connection where the peer
has stopped answering looks alive forever. The auditor's fake broker CONNACKs
and then never responds: after 4 s with `keepalive=1`, `connected?` and
`alive?` are both true and publishes still "succeed".
Fix: track the outstanding PINGREQ and close/reconnect when no type-13 packet
arrives within ~1.5 × keepalive.

#### T5-3 (high) `write_packet` has no write deadline **[re-verified]**

`mqtt5.rb:797-810` does a plain `socket.write(bytes)` under `@write_mutex`, and
the reader thread sends PUBACK/PINGREQ through that same mutex. Against a peer
that stops reading, the auditor measured `Timeout.timeout(4) { publish("big/topic",
"P" * 8MB) }` blocking past its timeout; once the socket buffer fills, keepalives
and PUBACKs block too and take the reader down with them.
Fix: `IO.select([], [socket], nil, WRITE_TIMEOUT)` plus a `write_nonblock`
loop that raises on timeout, so the existing teardown path fires.

#### T5-4 (high) A PUBACK with reason ≥ 0x80 is treated as success **[re-verified]**

```ruby
def handle_puback(body)                      # mqtt5.rb:778
  packet_id, = Codec.decode_puback(body)     # reason code discarded
  @state_mutex.synchronize { @pending_pubacks.delete(packet_id) }
end
```

`publish` has already returned `true`, so a broker rejecting the message
(`0x87 Not authorised`) is indistinguishable from delivery. SUBACK is handled
correctly (0x87 raises and rolls back), which makes the asymmetry worse.
Fix: keep the reason code and surface ≥ 0x80 as a publish failure.

#### T5-5 (high) A malformed QoS-3 PUBLISH is delivered as a real message **[auditor]**

`qos = (flags >> 1) & 0x03` (`mqtt5.rb:392`) yields 3 for header flags `0x6`,
and only `qos == 2` is special-cased (`:755-760`). MQTT 5 §3.3.1.2 defines
QoS 3 as a malformed packet requiring a disconnect. The auditor's fake broker
sent one and the subscriber received `["t", "qos3-payload", 3]`.
Fix: raise (and close) on `qos == 3` before dispatch.

#### T5-6 (medium) The core transport module never requires `json` **[re-verified]**

```
$ ruby -Ilib -e 'require "runes/transport"; puts defined?(JSON).inspect'
nil
$ ruby -Ilib -e 'require "runes/transport"; Message.new(payload: %q({"a":1})).parsed'
NameError: uninitialized constant Runes::Transport::JSON
```

`base.rb:29-30` uses `JSON.parse` and rescues `JSON::ParserError` with no
`require "json"`. `Message#request_id` (`:39`) takes the same path, so reply
correlation is broken for anyone who loads the transport standalone; it passes
in the suite only because another file required json first.
Fix: `require "json"` in `base.rb`.

#### T5-7 (medium) `TopicFilter` ignores the MQTT `$` rule — in-process and MQTT 5 disagree **[re-verified]**

The same defect as X5-4, found independently here and confirmed live against
mosquitto: with filter `#`, the in-process hub delivers
`$a2a/v1/discovery/...` and mosquitto does not. A2A lives entirely under
`$a2a/`, so this is not hypothetical. Fix once, in `TopicFilter#match?`: return
false when the topic starts with `$` and the filter's first level (after any
`$share/<group>/`) is `+` or `#`.

#### T5-8 (medium) A shared-group name containing `/` silently rewrites the subscription **[re-verified]**

```
$ ruby -Ilib -e '... split_shared(shared_filter("a/b","x"))'
parsed group="a" filter="b/x"
```

`RUNES_PROMPT_GROUP` feeds the group straight through, so a typo such as
`RUNES_PROMPT_GROUP=runes/prompts` makes the whole fleet subscribe to a
different filter and go **silently deaf** — no error, no traffic.
Fix: validate the group against `/\A[^\/+#\u0000]+\z/` in
`TopicFilter.shared_filter` and raise otherwise.

#### T5-9 (medium) `test/mcp_test.rb` depends on a gitignored file — the suite is not reproducible **[re-verified]**

```
$ grep -n "ECHO_SERVER" test/mcp_test.rb
20:  ECHO_SERVER = File.expand_path('../tmp/mcp_echo_server.rb', __dir__)
$ grep -n "^tmp" .gitignore
16:tmp/
```

The MCP client tests spawn `tmp/mcp_echo_server.rb`, which `tmp/` excludes from
version control. The suite therefore passes **only in this working copy**; in a
fresh clone or CI every MCP client test fails (the child cannot be exec'd and
each request times out). This is the finding that most undermines the "455
green" claim as evidence about a clean checkout.
Fix: move the fixture to `test/support/mcp_echo_server.rb`.

#### T5-10 (medium) MCP `Client#start` is not thread-safe **[auditor]**

`lib/runes/mcp/client.rb:60-70` has a `return self if open?` TOCTOU race across
`request` (`:101`) and `notify` (`:121`). Two concurrent requests spawn two
children; `close` reaps one and the first leaks.
Fix: a mutex with a double-checked `open?`.

#### T5-11 (medium) MCP line-framing caps are checked after the buffer grows **[auditor]**

`server.rb:44` reads with `@input.gets` and only then checks
`line.bytesize > MAX_MESSAGE_BYTES` (`:61`); `STDOUT_BUFFER_BYTES`
(`client.rb:25`) is referenced exactly once — its own definition — so it is
dead code despite `protocol.rb:39-42` claiming the cap is enforced. A peer
streaming bytes without a newline grows the buffer without limit.
Fix: bounded chunked reads, or `gets(limit)` plus rejection.

#### T5-12 (medium) An unvalidated A2A `taskId` becomes an MQTT topic **[auditor]**

`a2a/task.rb:68-76` passes `taskId` into the reply topic built at
`fabric.rb:257-263`, while the legacy delegation path validates
`from`/`request_id` explicitly (`fabric.rb:230-236`, the "D10" fix). The
auditor's `taskId="#"` produced `runes/prompts/#/response`; the first publish
raises inside the worker's rescue, so the task is dropped and the peer waits
forever. Fix: validate the id at the A2A boundary (reuse `REQUEST_ID_RE`) and
generate one when it fails.

#### T5-13 (low) Adapter and codec nits **[auditor, partly re-verified]**

- `A2A.discovery_wildcard()` → `$a2a/v1/discovery/-/+/+` and `task_wildcard()`
  → `$a2a/v1/tasks/-/-/+` because `segment("+") == "-"` (`a2a.rb:24,34`) —
  **re-verified**; latent only because callers pass `org`.
- `MQTT311#publish` skips the topic validation that `InProcess` and `MQTT5`
  perform (`mqtt311.rb:68-72`), so `bad/+/topic` is published without error —
  **re-verified**; `transport_test.rb:176` only exercises inproc.
- Non-minimal variable byte integers are accepted (`mqtt5.rb:823-833`).
- Topic aliases are unsupported; a PUBLISH with an empty topic is dropped
  silently.
- A repeated non-User-Property id is last-wins instead of a protocol error.
- CONNACK 0x24 (Maximum QoS) and 0x27 (Maximum Packet Size) are parsed and
  ignored, so Runes can exceed a broker's limits and be disconnected.
- In-flight QoS > 0 publishes are dropped on disconnect with no callback.
- `#` is honoured wherever it appears, so a malformed filter over-matches
  instead of being rejected.

#### Verified sound (transport) **[auditor]**

Bounds hold (a >16 MB remaining length is dropped as `:oversized`; a 4-byte VBI
overflow is rejected); partial and 1-byte-at-a-time reads reassemble correctly;
4 × 40 concurrent QoS 1 publishes arrive 160/160 without interleaving; a 1 MB
payload round-trips; live mosquitto gives exactly-once shared-subscription
dispatch, Response Topic / Correlation Data / User Property round-trip and
retained delivery to a late subscriber; CONNACK refusals (including the 3.1.1
`0x01` trap) and SUBACK 0x87 behave correctly; malformed property blocks raise
instead of reading out of bounds; MCP routes ids correctly under concurrency,
recovers from malformed JSON, reaps children on close and rejects traversal in
both the binstub and array-form commands.

#### Test gaps (transport)

The socket half of `mqtt5.rb` has **zero** coverage; the `$` rule and
empty-level `+` are unasserted; the shared-subscription and property contract
tests only ever run on the in-process hub, so the production MQTT 5 path for
the mechanism the design rests on is never contract-tested;
`mcp_test.rb:210-228` ("timeout does not kill the client") closes the hung
client and then tests a brand-new one, so it cannot fail; and there is no
concurrent `start`/`connect` test, which is why both leaks survive.

### W5 — Workflow engine and runes

#### W5-1 (critical) `cmd` executes through a shell, so a workflow argument is remote code execution **[re-verified]**

`CommandRunner.build_argv` (`lib/runes/command_runner.rb:95-101`) hands
`[command] + args` to `Open3.popen3`, and Ruby routes a **single-element argv
through the shell**. A String command therefore interpolates straight into
`/bin/sh`. Reproduced by me:

```
$ cat tmp/wf/inject.rb
execute do
  cmd(:leak) { "echo " + kwarg(:name).to_s }
  outputs { |_v, _i| cmd!(:leak).out }
end
$ ./bin/runes-workflow execute tmp/wf/inject.rb -- 'name=hello; echo INJECTED > tmp/wf/pwned'
hello
pwned file exists: YES
```

The shell behaviour is Roast's (the shipped example relies on it), but the
consequence is new: `runes-workflow execute FILE -- key=value` means any
workflow that interpolates a CLI value into a command String is **arbitrary
code execution from the command line** — and so is a one-element Array
(`cmd(:a) { ["echo x > file"] }`). The shipped example is safe;
`"git log #{kwarg(:ref)}"` is not.

Fix: `Shellwords.split` a String command (or reject it), never hand a
single-element argv to `popen3`, and add an explicit `shell: true` opt-in.
`test/workflow_engine_test.rb:610`/`:617` currently *enshrine* the shell
behaviour, so the tests must change with the fix.

#### W5-2 (high) `map parallel(n)` spawns one OS thread per item **[auditor]**

`map.rb:137` creates a `Thread.new` inside `each_with_index.map`; the
semaphore only throttles *execution*. With 800 items and `parallel(4)` the
auditor measured **807 peak threads**; 100k items exhausts threads and memory.
Fix: a fixed pool of `n` workers draining a `Queue`.

#### W5-3 (high) The `chat` rune ignores its entire config, and validates *after* sending **[auditor]**

`chat.rb:308-324` (`BaseBackend#chat`) and `:351-358` never pass `provider`,
`model`, `api_key`, `base_url` or `temperature` to `LLMClient#chat`, and
`valid_api_key!`, `valid_base_url`, `valid_temperature`,
`verify_model_exists?` are never called anywhere in `lib/`. Worse, with
`provider(:bogus_provider)` the auditor recorded the HTTP request being sent
*before* `InvalidConfigError` was raised — a typo in a provider name leaks the
prompt to the router's default provider and then fails.
`Chat::MaxTokensExceededError` (`chat.rb:19`) is dead code.
Fix: translate the config into the backend call and validate before sending.

#### W5-4 (high) `ExecutionManager#run!`'s `ensure` masks the original error and leaks a stale TaskGroup **[auditor]**

`execution_manager.rb:92-99` calls `compute_final_output` inside `ensure`; if
that raises (e.g. `outputs!` raising), it replaces the in-flight exception —
"ORIGINAL" is lost and "outputs boom" propagates — and aborts the rest of the
ensure, leaving `@running = true` and a **stopped** `TaskGroup` in the
thread-local, which every later `Rune#run!` would attach to.
Fix: keep `ensure` side-effect-only; restore state in an outer ensure.

#### W5-5 (medium) Async failures surface in start order, so a slow task hides a failure **[auditor]**

`task.rb:129-137` waits in start order: with two async runes where the first
sleeps 3 s and the second raises immediately, the exception surfaced only after
3.01 s — and if the first task never finishes, the failure is never observed.
Fix: wait on completion (a queue of finished tasks), raising the first error.

#### W5-6 (medium) `Bundler.with_unbundled_env` is not thread-safe, and every spawn uses it **[auditor]**

`command_runner.rb:57`/`:165-171`: two interleaved threads left
`BUNDLE_GEMFILE` nil, corrupting the process environment, so concurrent `cmd`
runes (`async!`, parallel `map`) can spawn children with the wrong env.
Fix: serialise with a mutex, or pass an explicit env hash to `popen3`.

#### W5-7 (medium) Aborting a scope neither stops nor joins running runes **[auditor]**

`task.rb:112-117` only sets a flag: an async rune that sleeps 1.5 s and has a
side effect still ran 2 s after a sibling `fail!` aborted the run, with the
thread and any exception unobserved. Fix: join outstanding tasks on stop.

#### W5-8 (medium) `TaskGroup#async` after `stop` still runs the block, untracked **[auditor]**

`task.rb:98-108` + `:21-32`: `mark_stopped!` lands *after* the thread starts,
so a post-stop `async` runs its block, reports `stopped? == true`, is
untracked, and swallows its exception. Fix: create the thread lazily under the
mutex, skipping when stopped.

#### W5-9 (medium) The agent rune's `working_directory` config is silently ignored **[auditor]**

`agent.rb:369-373` never passes `working_directory:` to the runner (Roast
does), so a configured working directory has no effect.
Fix: thread it through both provider invocations.

#### W5-10 (medium) There is no timeout anywhere — not on a rune, not on a run **[re-verified]**

`cmd.rb:140` and `agent.rb:369` never pass `timeout:` (CommandRunner supports
one; the DSL cannot reach it), `Cmd::Config` has no timeout option, and
`repeat.rb:80-91` loops forever without `max_iterations`/`break!` while
retaining each iteration's execution manager. I confirmed the unbounded case
needed `SIGKILL`:

```
$ timeout -s KILL 4 ./bin/runes-workflow execute tmp/wf/unbounded.rb ; echo $?
137        # still running at 4 s → no bound
```

An earlier plain `timeout 5` (SIGTERM) did *not* stop it either, which is its
own smell: the runner does not exit cleanly on TERM. Fix: expose `timeout` on
`cmd`/`agent`, add a workflow deadline, and bound `repeat`.

#### W5-11 (medium) `ConfigManager` grows without bound for anonymous runes in loops **[auditor]**

`config_manager.rb:57,59-62,132-134` keys name-scoped configs by rune name,
including the UUID of anonymous runes: 60 `repeat` iterations with one
anonymous rune produced 61 config entries, and each iteration's
`ExecutionManager` is retained until the output is dropped.
Fix: skip name-scoped configs for anonymous runes.

#### W5-12 (medium) Workflow test quality **[auditor; the `test_helper` gap re-verified]**

- The `map` parallel path has **zero** coverage (`grep -rn parallel test/` →
  nothing): the riskiest concurrency code in the new layer is untested.
- `workflow_engine_test.rb:416-427` passes if `async!` is a no-op.
- `workflow_cli_test.rb:117-132` passes a target but only asserts the
  top-level output, so it would pass with no target at all.
- `workflow_engine_test.rb:610-615` claims "never uses a shell" while covering
  only ≥ 2-element argv — false for a 1-element Array (W5-1).
- `test/test_helper.rb:16` says provider keys are stripped but removes only
  `DEEPSEEK`/`SYNTHETIC`/`CEREBRAS`; **OPENAI, ANTHROPIC, GEMINI, PERPLEXITY
  keys and `RUNES_LLM_ADAPTER` are untouched** — re-verified by reading the
  same six lines I had relied on when I wrote the opposite.

#### W5-13 (low) Smaller workflow findings **[auditor]**

`CogInputContext#bind_rune_type` (`:65-72`) has no name guard, unlike its two
siblings, so a rune named `template`/`params`/`args`/`tmpdir` silently breaks
workflow params. `Runes.deep_dup` (`util.rb:16-35`) duplicates IO objects (a
fresh fd per rune per iteration). Roast deltas verified against upstream:
top-level `next!` is swallowed here and raises there; `Config#field` returns
`false` where Roast returns the default; `Config#merge` deep-dups where Roast
is shallow; `Ruby::Output#call(:key, x)` drops the key (fixing a Roast bug);
`Map::Config#parallel(negative)` means "unlimited" in both, making its own
negative check unreachable. `Workflow.from_file` deletes the tmpdir before
returning.

---

### O5 — The observatory

#### O5-1 (critical) One non-UTF-8 payload wedges ingest forever and duplicates every retained message **[auditor]**

`packet_recorder.rb:107` keeps `payload.to_s` as ASCII-8BIT, and the `.scrub`
in `truncate` (`:177`) is a no-op on a BINARY string, so sqlite3 raises
`Encoding::UndefinedConversionError` on bind. `record` raises →
`MqttIngest#run` rescues and reconnects → the broker replays the retained
message → the loop repeats. MQTT payloads are arbitrary bytes, so any buggy or
hostile publisher triggers it. The auditor's 8-second live run with one
retained invalid card plus one healthy card:

```
connect attempts in 8s : 4
packets stored         : 4   ("runes/agents/ok/card" => 4)   ← 4 duplicate rows
ingest state           : disconnected, Encoding::UndefinedConversionError
```

Fix: `@payload = payload.to_s.dup.force_encoding(Encoding::UTF_8).scrub` at
the storage boundary, **and** a per-message rescue in `connect_and_consume`
that drops one bad message with a counter instead of tearing down the
connection.

#### O5-2 (high) `/feed` can return 50 MiB per poll per tab **[auditor]**

`packets_controller.rb:2,19` ships whole payloads (each capped at 256 KiB by
`packet.rb:17`) and the poller runs every 2.5 s. With 200 packets of 255 KiB:
`GET /feed?after_id=0` → **50.2 MiB in 384 ms**; `GET /packets` → 50.2 MiB;
`GET /` → 20.1 MiB. The Stimulus `trim` bounds *nodes* (400), not bytes, so a
browser accumulates ~100 MiB of text.
Fix: serve a summary (headline + first ~2 KiB), fetch full payloads on demand,
and make `trim` byte-aware.

#### O5-3 (high) The ingest's DB-failure path is not failure-safe — the process dies **[auditor]**

`mqtt_ingest.rb:33-46` rescues a record failure by calling
`IngestStatus.mark_disconnected!`, which also writes; under a locked database
that raises out of the rescue, past the `ensure` (which raises the same way)
and out of `run`. Measured with a second connection holding `BEGIN EXCLUSIVE`:
`PacketRecorder.record` → `StatementTimeout`; `mark_disconnected!` →
`SQLite3::BusyException: database is locked`; the `ensure` raised too.
Fix: make the status writers never raise (rescue and log inside) and count the
dropped message.

#### O5-4 (high) `/agents/:id` renders every packet of every interaction **[auditor]**

`agents_controller.rb:41-50` loads all packets for all of an agent's
requests/leases and `agents/show.html.erb:57-76` renders a partial per packet.
With 200k rows and one busy agent (5 000 requests × 8 packets): **48.9 MB /
3.83 s**. Fix: paginate interactions, cap packets per interaction.

#### O5-5 (high) Agent attribution is broken for real traffic — 1 row in 4 **[re-verified]**

This is the consequence of X5-1, and it is much worse than dead code: because
the classifier only attributes an agent from the deleted claim/started/session
topics, traffic the dispatcher actually publishes has `agent_id = NULL` until
the trailing journal entry. Reproduced by me, replaying the real shapes:

```
$ RAILS_ENV=test bin/rails runner tmp/attr_probe.rb
  prompt     agent_id=nil
  progress   agent_id=nil
  response   agent_id=nil
  journal    agent_id="runes-a"
rows for request x1: 1/4 have an agent_id
```

The auditor measured the same over a full synthetic session (2/7 rows), so
`/packets?agent_id=…` shows a fraction of the traffic and the per-agent page
is mostly empty — while the tests pass, because
`packet_recorder_test.rb:57,101` and `fixtures/packets.yml` assert attribution
through the dead topics. Fix: delete the dead grammar (X5-1) and backfill a
request's rows when the executor becomes known (journal entry, or a
`from`/`agent` envelope field).

#### O5-6 (medium) Retained replay, dedupe, retention and the poller **[auditor]**

- A retained card replay sets `last_seen_at = now` (`agent.rb:31-60`), so a
  dead agent returns as `online` and `stale?` can never stick — with O5-1's
  reconnect loop, refreshing every 1-30 s forever. Fix: ignore retained
  replays (use the transport's `retain` flag) or suppress agent bookkeeping
  during the post-SUBSCRIBE window.
- There is no dedupe: four reconnects stored one retained card four times.
- `RUNES_OBSERVER_MAX_PACKETS=0` (or any non-numeric value) becomes
  `prune!(days: 0)` and **deletes the whole table**; verified, 5 000 rows
  gone. Treat `<= 0` as "no cap" and warn on a non-numeric value.
- Retention runs only inside the ingest process and never prunes agents, so a
  wedged ingest (O5-1) removes the only backstop.
- The poller has no in-flight guard (`feed_controller.js:21-56`): overlapping
  polls re-insert the same rows and duplicate DOM ids, and `!ok` retries
  forever with no backoff.
- Payload search is an unindexed `SCAN packets` with unescaped LIKE
  metacharacters (`packets_controller.rb:61-62`); `q=%` forces a full scan.

#### O5-7 (low) Observatory nits **[auditor]**

`IngestStatus` cannot see a dead ingest (`:51-60`) and `mark_connected!` runs a
full `Packet.count` per reconnect; the layout adds `Packet.count` +
`Agent.count` on top of the controller's `@total`; `/feed/stats` is dead (the
JS never calls it); `IngestStatus.current`'s `first_or_create!` races on the
first concurrent request; dead code (`Packet#request_scoped?`,
`Agent#duration`, `Packet#pretty_payload`, the claim/session `KINDS`);
`Agent#packet_count` never counts card/status packets and is never decremented
when packets are pruned.

#### Verified sound (observatory) **[auditor, plus my own escaping check]**

Escaping is correct end to end: there is no `raw`/`html_safe`/`sanitize`/
`<%==` anywhere in `app/` (I verified this independently), hostile
`<script>`, `<img onerror>` and `" onmouseover="` payloads come back escaped in
titles, headlines, `<pre>`, `data-*`, datalists and flash, `/feed` escapes
before embedding HTML in JSON so `insertAdjacentHTML` cannot execute it, and
hostile ids are percent-encoded in links. No SQL injection (bound params only,
no param-driven `order`/`group`), no SSRF or path traversal, no N+1
(`/` = 12, `/packets` = 6, `/feed` = 4, `/interactions/:id` = 4 statements).
The subscription set carries no group and no `$share/` filter, so the observer
cannot steal prompts. `PacketClassifier` matches every topic the harness
actually publishes — and **no workflow/guard/MCP topics exist on the wire at
all**, so nothing live is missed: the Phase 17 vocabulary is a roadmap gap,
not a regression. `record_card!` never flips state. The auditor also
**corrected a premise of my own roadmap**: `prune!` is not a performance
problem at the stated cap (0.4-2.2 ms at 200k rows), so OBSERVATORY_ROADMAP's
O0.4 framing was wrong — the real observatory limits are payload bytes (O5-2)
and unbounded per-agent rendering (O5-4).

#### Test quality (observatory) **[auditor]**

`packet_recorder_test.rb:57,101` and all of `fixtures/packets.yml` assert
attribution through topics the harness no longer publishes, so they are green
and vacuous while reality stores `agent_id = NULL` (O5-5);
`demo_fabric_test.rb` asserts the seeder's own invented protocol;
`packet_test.rb:20,32` and `packet_classifier_test.rb:42-70` cover dead kinds
as if live; `packets_controller_test.rb:44` can never exercise `PER_PAGE=200`
with five fixtures; and the untested risky paths are exactly the ones that
failed above (non-UTF-8 payloads, SQLite contention, retained replay,
`prune!`'s `max:` branch, 256 KiB payloads through `/feed`, overlapping polls).

---

### D5 — Tests and documentation

The suite passes on three seeds (455 runs, 0 failures), and the observatory
passes 61/348. What follows is what those runs do *not* prove.

#### D5-1 (high) The suite is not hermetic: 15 tests require a live broker on port 1883 **[re-verified]**

`test/second_audit_test.rb:33,208` build
`Runes::Transport::MQTT311.new(host: '127.0.0.1', port: @port, …)`, and
`@port` is **never assigned** anywhere in the file, so the `mqtt` gem falls
back to its default 1883. Reproduced by blocking the default port:

```
$ ruby -Ilib -Itest -e 'require "mqtt"; MQTT::DEFAULT_PORT = 1; require "./test/second_audit_test.rb"'
Runes::Transport::Error: MQTT 3.1.1 connect to 127.0.0.1: failed: Errno::ECONNREFUSED: … port 1
15 runs, 0 assertions, 0 failures, 15 errors, 0 skips
```

So a machine with no broker on 1883 gets 15 errors, and the tests are also
vacuously connected — most of them never publish over that transport. This
falsifies `README.md:465-470` ("hermetic and offline … no network call,
ever"), `STATE.md` ("hermetic (no broker, no API keys)"), and — correcting my
own text from the previous round — `docs/WHY_RUNES.md` ("no broker required",
"no network, no keys, no broker"), which I have now fixed (see the note at the
end of this section). Fix: spawn an in-process broker on a free port in those
tests, or use `RecordingTransport`.

#### D5-2 (high) The registry leak makes the assertion count order-dependent **[auditor]**

`test/workflow_engine_test.rb:527-548` declares `WorkflowEngineFake` through
`plugin`, and `Runes::Plugin.declared` is permanent, so `reset!` resurrects it
forever (this is X5-3's mechanism at test scale). Running that one method
grows `Plugin.names(kind: :rune)` from 10 to 11; `test/plugin_test.rb:35`
asserts per entry, so its assertion count varies with test order — which is
why three seeds gave 2082, 2083 and 2083. `test/plugin_test.rb:9-10` even
carries a comment admitting the workaround ("assert membership, not
equality"). Fix: snapshot and restore the registry, or rebuild `reset!` from
an explicit built-in list rather than `declared`.

#### D5-3 (medium) Tests that cannot fail **[auditor]**

- `third_audit_test.rb:296-302` defines a **local** regex and asserts literals
  against it — it touches no production code, so it passes if every real
  agent-id validator is deleted (this is exactly the gap X5-2 reports).
- `verifier_followup_test.rb:233-234` asserts a constant equals
  `Broker::const_get(same_constant)`.
- `fabric_test.rb:146-163` is titled "…answered on its response topic" but
  never asserts a reply was published; its only substantive assertion is
  guarded by `if d.respond_to?(:parsed_request_id_for_last_task)` — a method
  that exists nowhere in `lib/` — so it never runs and the test passes if the
  reply path is deleted.
- `roast_compatibility_test.rb:183-194` (`test_no_network_is_touched`) only
  asserts the three fakes were called; an *additional* real HTTP call would go
  undetected.
- `third_audit_test.rb:306-309` and `verifier_followup_test.rb:215-219` assert
  broker constants rather than behaviour.
- `broadcast_lease_test.rb` spawns a real broker in `setup` that none of its
  tests use, and still sets the deleted `RUNES_CLAIM_WINDOW_S` knob (also at
  `mode_commands_test.rb:18`, `cli_tools_test.rb:134,137`).

#### D5-4 (medium) Missing negative tests **[auditor]**

No test signs a payload with key B while claiming trusted key A's `kid`
(signature **forgery**; only `:unknown_key` and tampering are covered). No
test feeds a malformed CONNACK/PUBLISH over a live socket (codec-level
negatives only). No test executes a raw `raise "boom"` in a `ruby` rune body,
so the observable behaviour of a raising rune (wrapped error? abort? do later
runes run?) is unspecified — and that is precisely the path W5-4 corrupts.

#### D5-5 (low) Documentation drift

The full list is in the audit transcript; the load-bearing ones:
`GEM_PACKAGING.md:94-102` says five executables and that `runes-acl` is
deliberately not installed (the gemspec and `packaging_test.rb:76` list
**seven**, including `runes-acl` and `runes-workflow`); `docs/SECURITY.md`
still says the dispatcher "does not yet verify incoming envelopes" (false
since Phase 16) and still treats the claim/lease protocol as live
(`:38-40,54-58,249-255,368-370`) — and note that D5-5's sibling finding
matters: per S5-1 that verification is *incomplete* anyway, so the doc is
wrong in both directions; `docs/WHY_RUNES.md` and `STATE.md` quote "77 files"
(the gem has **75**) and `STATE.md:39` says `cmd` is 150 lines (157);
`README.md:244-249` claims runes are addressable "by the capability guard"
(they are not — `STATE.md` gap 1, `docs/WORKFLOWS.md` § "Not yet done");
`README.md:101-103` says "default-deny … any policy error fails closed", while
the shipped config is allow-all for `write_file`/`read_file`/`run_command`
(with a warning printed on every suite run) and S5-3 shows a malformed policy
fails open; `README.md:480` claims the VM manager is tested "mock + real"
though `wasmtime` is installed and no test runs the real backend;
`bin/runes-client:4,106-110` still documents the deleted claim/lease
protocol; `docs/OBSERVATORY_ROADMAP.md:434` says "~1 000 lines" (1 947); and
**no `LICENSE` file exists** although the gemspec declares MIT.

#### Corrections made during this round

Two claims in documents I wrote myself were falsified by this audit and are
corrected in place rather than merely reported: the "no broker required"
sentence in `docs/WHY_RUNES.md` (D5-1) and the hermeticity line in
`STATE.md`. The remaining drift above is *reported*, not fixed — fixing it is
a follow-up task, and doing it inside an audit would hide how much there is.

---

## Part 3 — Proposed enhancements

### E5-1 — One topic matcher, and a conformance matrix (fixes X5-4)

Replace the three implementations with `Runes::Transport::TopicFilter`, made
spec-correct, and add the table from X5-4 as a unit test. Cheap, and it
removes a class of divergence permanently.

### E5-2 — A publisher↔observer contract test (fixes X5-1)

The observatory's classifier is a *copy* of the harness's topic grammar, and
nothing checks the two against each other — which is how the lease vocabulary
survived a protocol deletion. Proposed: a test that runs a real dispatcher
against the in-process hub, records every topic it publishes during a scripted
session (prompt, goal, plan, mission, A2A task, tool RPC), and asserts each
one classifies to a non-`other` kind, plus the reverse: every classifier
pattern has a producer or is deleted. This is the single highest-leverage
test in the repository: it makes drift a build failure instead of a demo.

### E5-3 — Validate identity where it is created, not where it is used (fixes X5-2)

Validate `agent_id` at dispatcher construction against `AGENT_ID_RE`, and add
a test asserting the legacy card topic and the A2A discovery topic yield the
same observer `agent_id` for a hostile id (spaces, `:`, `/`, unicode, `+`,
`#`, 65 chars).

### E5-4 — Make the plugin registry's reset path atomic (fixes X5-3)

Record declarations only on success; rebuild with `replace: true`; add the
two-declarations-one-name case as a test (including "the runes are still all
registered afterwards").

### E5-5 — Run the wire-level suite against a real broker too

The in-process hub is a *model* of MQTT, and X5-4 shows the model is wrong in
at least three places. Add a thin conformance harness that runs the same
assertions against `RUNES_TRANSPORT=mqtt5` when `127.0.0.1:1883` is reachable
and skips otherwise (the live MQTT 5 check already proves this is feasible).
Divergences then surface at the point of change rather than in production.

### E5-6 — Make runes guard-aware, opt-in (from `docs/WORKFLOWS.md`)

`cmd` and `agent` currently execute without consulting the capability guard,
and a single-string `cmd` is shell-interpreted exactly as Roast does. Both
are documented, neither is *safe* to leave forever. Proposed: a workflow-runner
policy (`RUNES_WORKFLOW_POLICY=path`) that maps `cmd` to an `:exec` action on
the resolved argv and `agent` to its CLI, defaulting to off so unmodified
Roast files keep working, and a `--dry-run` flag that reports which runes
*would* be refused. This is the item that turns "a rune is a plugin" from a
structural claim into a safety property.

### E5-7 — Telemetry for the workflow engine (from `docs/OBSERVATORY_ROADMAP.md` O1.1)

`Runes::Workflow.telemetry = ->(event) {}` plus a transport sink publishing
`runes/workflows/<run_id>/…`: the newest, least observable code in the project
becomes the best-observed, and the observatory gains run/step objects. ~20
lines in the engine, which is why it is odd that it is still missing.

### E5-8 — A deletion checklist for retired protocols

X5-1 exists because "delete the consensus" was scoped to `lib/`. A one-page
`docs/RETIREMENT.md` process — grep the vocabulary across `lib/`, `bin/`,
`runes_observer/`, `test/`, `docs/`, `config/`; delete the tests that pin it;
migrate the columns — would have caught it. Cheap, and this is the second
protocol this repository has retired.

### E5-9 — Stop advertising kinds that cannot occur

`Packet::KINDS` is the filter vocabulary the UI offers. Derive it from the
classifier (or assert every kind is reachable in the contract test of E5-2),
so the UI cannot offer a filter that is guaranteed to return nothing.

### E5-10 — A CI oracle endpoint for fleet hygiene

`GET /api/v1/health.json` reporting unsigned publishers, signature failures,
orphaned prompts and guard denials, so an integration run can assert "the
fleet behaved" the way a test suite asserts code behaved. This is the
observatory's most useful future role and it costs one controller.

### E5-11 — One command-policy checker, and real confinement (fixes S5-2)

Extract the token scan from `Dispatcher` and `bin/runes-mcp` into one
checker, default to a small non-interpreter allowlist, refuse interpreter
first-arguments and attached-option paths, and treat an unclassifiable token
as a violation. Then add actual confinement (`sandbox-exec` on macOS,
`bwrap` on Linux) for `run_command`, so the boundary is the kernel's rather
than a parser's. The current test must be replaced with one that asserts no
file appears outside the workspace for interpreter and attached-arg payloads.

### E5-12 — Verify on every inbound path, not the convenient one (fixes S5-1)

Move the `verify_signed!` gate into `handle_prompt` (or a wrapper that all
three inbound handlers call) so a new subscription cannot forget it, and make
`verify_signed!` return the *verified* envelope so callers cannot execute the
pre-verification parse. Add `bin/runes-client --agent` signing. Negative
tests for the delegated and A2A paths belong in `fabric_test.rb`.

### E5-13 — Freshness for RPC and envelopes (fixes S5-4)

A `{ts, nonce}` MAC with a bounded seen-nonce set, per-agent RPC topics, and
removal of the fleet-wide `runes/tools/+/request` read from the generated
ACL. Without freshness, "authenticated" means "was once authenticated".

### E5-14 — A policy that cannot be read is not a policy (fixes S5-3)

Load the policy before merging the baseline; if an explicitly configured
policy fails to parse, drop the baseline or refuse to boot, and print the
*effective* policy (which tools have which actions) at startup. The current
warning asserts the opposite of what the code does.

### E5-15 — Redact route inspection

`LLMClient::Route` is a `Struct`, so `p route` prints `api_key`. Override
`#inspect` (and check any other struct holding a secret) so a debug `p` in a
console or a crash report cannot leak a key.

### E5-16 — Reconnect, re-subscribe, and report it (fixes T5-1)

An exponential-backoff reconnect loop in `read_loop`'s `ensure` that re-sends
CONNECT and re-SUBSCRIBEs every live `Subscription`, plus a `health` hook the
dispatcher can subscribe to (the observatory could then show it). This is the
single most important fix in the round: without it, every other guarantee is
conditional on a TCP connection that never drops.

### E5-17 — Make the client fail loudly when the peer stops listening (fixes T5-2..T5-5)

Verify PINGRESP and close when it is overdue; give `write_packet` an
`IO.select` deadline; keep PUBACK reason codes and surface ≥ 0x80; treat QoS 3
as malformed. Four small changes that turn "silently wedged" into "reconnected
and visible".

### E5-18 — Validate what becomes a topic (fixes T5-8, T5-12, and the A2A wildcard defaults)

One validator for group names, agent ids, request ids and A2A task ids, used by
`TopicFilter.shared_filter`, `A2A.segment`, the delegation path and the A2A
task path — the legacy path already has it, the others do not. Also `require
"json"` in `transport/base.rb` (T5-6).

### E5-19 — A `FakeBroker` helper, and move the MCP fixture into the suite

An in-memory `TCPServer` that can CONNACK, NACK, ignore, stall or answer
slowly, so the socket half of `mqtt5.rb` (reconnect, keepalive, write
deadline, PUBACK, QoS 3, oversized, partial reads) becomes testable without a
real broker; plus moving `tmp/mcp_echo_server.rb` to `test/support/` and
gating `tmp/verify_mqtt5_live.rb` behind an ENV var so CI can run it when a
broker exists. This is what makes T5-1..T5-5 non-recurring.


### E5-20 — Make `cmd` argv-safe (fixes W5-1)

`Shellwords.split` a String command (or reject it with a clear error), never
pass a single-element argv to `popen3`, and add an explicit `shell: true`
opt-in for the rare case that needs it. Fix the two tests that currently assert
the shell behaviour, and add an injection regression test using a hostile
kwarg. Until this lands, `runes-workflow execute FILE -- key=value` should be
treated as running untrusted code.

### E5-21 — Make ingest unkillable by one bad message (fixes O5-1, O5-3)

Scrub payloads to valid UTF-8 at the storage boundary (recording that it
happened), wrap each `PacketRecorder.record` in a rescue that counts and drops
one message, and make every `IngestStatus` writer non-raising. Add a `dropped`
counter to the health row so the loss is visible. This turns "one byte kills
the observer" into "one row is marked lossy".

### E5-22 — A bounded, byte-aware feed (fixes O5-2, O5-4)

A `packet_summaries` projection (headline + first ~2 KiB) served by `/feed`,
full payloads on demand, a byte budget in the JS `trim`, an in-flight guard and
backoff in the poller, and pagination plus a per-interaction cap on
`/agents/:id`. The observatory currently renders whatever it is given; at
255 KiB per packet that is a self-inflicted denial of service.

### E5-23 — Bound the engine (fixes W5-2, W5-5, W5-10, W5-11)

A fixed-size worker pool for `TaskGroup`/`map` instead of one thread per item;
completion-ordered waiting so a slow task cannot hide a failure; a `timeout`
config on `cmd`/`agent` plus a workflow-level deadline; and no name-scoped
config for anonymous runes. These are what make a rune loop safe to put behind
a button (roadmap O1.2).

### E5-24 — Make `chat` honour its own configuration (fixes W5-3)

Pass `provider`/`model`/`api_key`/`base_url`/`temperature` through to the
router (or an explicit adapter), validate *before* the request, and delete or
implement `MaxTokensExceededError`. Today the entire documented config surface
of the most-used rune is decorative — and a provider typo sends the prompt to
the wrong provider first.

### E5-25 — Make the suite actually hermetic (fixes D5-1, D5-2)

Spawn a broker on a free port (or use `RecordingTransport`) in
`second_audit_test.rb`; snapshot and restore the plugin registry instead of
relying on `declared`; strip *all* provider keys and `RUNES_LLM_ADAPTER` in
`test_helper.rb`; and add the missing negatives (signature forgery, malformed
frames over a live socket, a raising rune). A suite whose greenness depends on
a broker and on test order cannot be the evidence base for a security claim —
which is how S5-1, S5-2 and O5-5 survived.

---

## Part 4 — Suggested priority

| # | Item | Why first |
| --- | --- | --- |
| 1 | **T5-1 / E5-16** reconnect and re-subscribe | a lost connection is a silent, permanent black hole that looks healthy |
| 1= | **W5-1 / E5-20** stop `cmd` interpolating into a shell | a workflow argument is remote code execution |
| 1= | **O5-1 / E5-21** scrub payloads, isolate per-message failures | one bad byte wedges ingest forever and duplicates retained state |
| 1= | **O5-5 + X5-1 / E5-2** attribute real traffic, delete the dead grammar | the fleet view and agent filter do not work on live data |
| 2 | **D5-1** make the hermetic claim true | 15 tests dial a real broker; the claim is currently false |
| 2 | **T5-2..T5-5 / E5-17** keepalive, write deadline, PUBACK, QoS 3 | the rest of the lifecycle failures: a wedged peer hangs the client, a NACK is invisible |
| 3 | **T5-9** move the MCP echo fixture into `test/` | the suite is not reproducible from a clean checkout today |
| 4 | **S5-1 / E5-12** verify signatures on every inbound path | a documented guarantee that does not hold; unauthenticated prompt execution |
| 5 | **S5-2 / E5-11** finish `run_command` confinement | arbitrary read/write/exec outside the workspace by default; round-4 regression |
| 6 | **S5-3 / E5-14** fail closed on a malformed policy | a JSON typo silently keeps allow-all on write/read/exec |
| 7 | **X5-4 / T5-7 / E5-1** one topic matcher | affects every delivery decision, and one variant is fail-open |
| 8 | **E5-2** publisher↔observer contract test | stops the class of drift that produced X5-1 |
| 9 | **X5-1** delete the dead lease vocabulary | user-visible fiction in the demo and UI |
| 10 | **X5-2 / E5-3** validate agent ids | silent identity splitting |
| 11 | **X5-3 / E5-4** atomic registry reset | small, and it is a trap for every future test |
| 12 | **T5-6 / T5-8 / T5-12 / E5-18** transport hygiene | a missing `require`, an unvalidated group name, an unvalidated task id |
| 13 | **S5-4 / E5-13** nonce freshness, per-agent RPC topics | replay + a fleet-readable secret |
| 14 | **E5-7** workflow telemetry | makes Phase 17 observable |
| 15 | **E5-6** guard-aware runes | the documented safety gap |
| 16 | **E5-5 / E5-19** live-broker conformance + `FakeBroker` helper | prevents the next T5-1…T5-5 |
| 17 | **E5-9 / E5-10 / E5-8 / S5-5..S5-8** | hygiene and process |

---

## Appendix — reproductions

Every finding above was produced with one of these (run from the repository
root):

```bash
# X5-1 — the harness cannot produce the demo's claim/lease topics
grep -rn "runes/sessions" lib bin                  # nothing
grep -n "claim\|started" runes_observer/app/services/demo_fabric.rb

# X5-2 — one agent id, two observer identities
ruby -e 'require_relative "lib/runes/a2a"; require_relative "runes_observer/app/services/packet_classifier"; ...'

# X5-3 — reset! aborts and half-rebuilds
ruby -Ilib -e 'require "runes/plugin"; A = Class.new(Runes::Plugin); ...'

# X5-4 — the matcher matrix and the hub's $-topic leak
ruby -Ilib -e 'require "runes/transport/topic_filter"; require "runes/capabilities/guard"; ...'
ruby -Ilib -e 'require "runes/transport"; t = Runes::Transport.build(kind: :inproc); ...'
```

Suites at the close of this round, re-run after every edit made during the
audit: parent **455 runs / 2 083 assertions / 0 failures / 0 errors / 0
skips**; observatory **61 runs / 348 assertions / 0 failures / 0 errors / 0
skips**. A second parent run under a different seed reports 2 082 assertions
— see D5-2 for why, which is itself one of the findings.

Two claims in documents written during this project were falsified by this
audit and corrected in place (rather than only reported): the "no broker"
sentence in `docs/WHY_RUNES.md` (D5-1) and the hermeticity line in
`STATE.md`, plus the two counts in `STATE.md` (150 → 157 lines) and
`docs/WHY_RUNES.md` (77 → 75 files). Everything else this round reports;
none of the flaws above were fixed, deliberately, because an audit that
silently repairs its own findings cannot be reviewed.
