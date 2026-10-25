# The WASI transport guest — the first real guest

> Status: adapter + guest + bridge protocol land in Phase 41. The hermetic
> suite (CRuby-spawned guest) is green, and the real ruby.wasm boundary
> test passes (opt-in `RUNES_WASM=real`, ~12 s module compile). The VM runs
> in a child OS process — see "Why the VM runs in a child process".

The WASM sandbox (`Runes::WASM::VMManager`) runs **one-shot, stateless**
guests: a tool script goes in on stdin, its output comes back, the VM is
done. The transport guest is the first **long-lived, stateful** guest: it
*is* a fabric peer. Its fabric state — subscriptions, retained messages,
shared-group round-robin — lives inside the guest, and the host talks to it
through the ordinary `Runes::Transport::Base` contract
(`lib/runes/transport/wasi_guest.rb`).

## Why files, not pipes

WASI p1 gives a guest a preopened directory and nothing else that is
reliably bidirectional: stdout is consumed by the host only as a log
 (`set_stdout_file`), a FIFO stdin busy-polls under wasmtime (observed:
 the spin wedges the whole VM), and `ruby -e` frees stdin only because the
 program rides argv. So the bridge is numbered JSON files on the mapped
 work directory, both directions, `tmp` + `rename` for atomicity:

```
work/
  inbox/%06d.json          host -> guest ops (subscribe/unsubscribe/
                           publish/stop, each with "ref")
  outbox/%06d_<kind>.json  guest -> host frames (hello / ack / delivery)
  guest.log                the guest's own log (whole-file rewrites —
                           WASI p1 append-mode opens are the least
                           uniformly implemented bit across runtimes)
```

Both sides skip `tmp_*` names in their glob — a tmp hit means
"write in progress", and the rename is the visibility point. Acks come
**after** the op is applied, so a publish can never overtake the
subscribe it depends on across the bridge.

## The guest program is the same bytes under three runtimes

`wasm/transport_guest.rb` is plain Ruby, no third-party requires (ruby.wasm
ships **without** the `json` gem — the guest carries its own minimal
JSON-subset codec, interoperable with the host's full JSON both directions;
payloads are opaque strings on the wire, never parsed by the guest):

- **CRuby** — the suite spawns it directly (`spawn` injection); every
  protocol and contract behavior is tested hermetically this way.
- **ruby.wasm** — the adapter's default `spawn` embeds the source via
  `ruby -e`, work dir mapped to `/work`.
- **Spinel later** — the file stays inside the subset; the compiled fleet
  runtime (bake a loaded world into a kernel) reuses this bridge, which is
  the point: the protocol is the seam that lets a compiled agent hold
  fabric state.

## Why the VM runs in a child process

The first in-process implementation started `instance.invoke("_start")` on a
thread and pumped frames from another. It wedged as soon as the guest
entered its poll loop: wasmtime-ruby holds the CRuby GVL while guest code
executes, so the pump thread, the boot timer and every watchdog stopped
being scheduled. Micro-probes cleared the filesystem suspects — boot,
`sleep`, `Dir.glob` (empty and populated), `Dir.mkdir`/`EEXIST`,
`File.delete` and `File.rename` all complete under ruby.wasm — and showed
the real shape: a guest heartbeat loop kept running for 40 s while the host
wrote zero heartbeats, and a finite guest run let the host resume only
after the guest exited. `wasm/wasm_host.rb` now owns the VM in a child OS
process (`wasm/wasm_host.rb WORK_DIR WASM_PATH GUEST_PATH`); the adapter
keeps only the file bridge and a `Process`-backed handle. Boot takes ~12 s
(module compile) and the parent stays responsive throughout.

## Using it

```ruby
transport = Runes::Transport.build(kind: "wasi_guest") # ruby.wasm in a child process
# or inject another runtime:
Runes::Transport::WasiGuest.new(spawn: ->(work_dir:, program_path:, **) { ... })
```

`connect` waits for the guest's hello frame (boot is the expensive part —
compiling the 37 MB ruby.wasm module takes ~12 s), then the adapter
is a normal transport: `supports_groups?` and `supports_properties?` are
true; `publish` acks synchronously across the bridge; `disconnect` stops
the guest child, reaps it, and removes the scratch work dir.

## Verification status (honest)

- `test/wasi_guest_test.rb` — 11 hermetic tests through a CRuby-spawned
  guest: round trip, retained replay + wildcards, shared-group exactly-once
  splitting, properties intact, unsubscribe, disconnect cleanup, ordering,
  error paths, `Transport.build` wiring. Green in the suite.
- `RUNES_WASM=real` boots the actual ruby.wasm under wasmtime for one
  end-to-end round trip. Opt-in because of the compile cost; it is the
  canary for WASI-runtime-specific behavior (the file-op choices above
  were all found by running it, not by reading docs).
- **Real-wasm status: closed 2026-10-24.** The earlier wedge was GVL
  starvation from the in-process VM, not a WASI preopen op (the probes
  above cleared `Dir.glob`/`File.delete`/`sleep`). With the child-process
  host the canary passes in ~12 s (1 run / 1 assertion) and the whole file
  is 12 runs / 30 assertions / 0 failures / 0 skips under `RUNES_WASM=real`.
