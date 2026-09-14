# Gem Packaging

How to build, install, publish and embed the `runes` harness as a Ruby gem,
what actually ships, and how the optional WASM sandbox and the LLM
provider-adapter seam fit in.

## Build

```sh
cd /path/to/runic
gem build runes.gemspec          # -> runes-0.3.0.gem
```

`runes.gemspec` derives its version from `Runes::VERSION`
(`lib/runes/version.rb`), so a release is: bump that constant, rebuild.

`gem build` may print `WARNING: <file> is not world-readable` for files whose
mode is `0600`. That is a checkout-permission artifact, not a packaging bug;
fix with `chmod 644` on the offending files if the warning matters to you.

## Install

```sh
gem install ./runes-0.3.0.gem       # system/user gems
# or, per-project:
bundle add runes                    # once the gem is published
gem 'runes', path: '/path/to/runic' # from a local checkout
```

Then:

```ruby
require 'runes'
Runes::VERSION              # => "0.3.0"
Runes::Core::LLMClient      # default LLM router
Runes::LLM.adapter          # same object, through the seam
```

`require "runes"` is deliberately dependency-light: it opens no broker
connection, touches no database and makes no network call. It loads the
version, transports, A2A helpers, settings, the LLM router and seam, the plan
parser, tool registry, capability guard, the dispatcher (when possible) and the
WASM manager.

## Publish

```sh
gem signin                      # rubyGems.org credentials
gem build runes.gemspec
gem push runes-0.3.0.gem
```

`spec.homepage` in `runes.gemspec` points at the public repository
(`https://github.com/La-Voix-du-chat-artiste/runes`). `source_code_uri` and
`changelog_uri` are derived from it, so if the project ever moves, update it
there first — `changelog_uri` hard-codes the `master` branch.
`rubygems_mfa_required` is set.

## What ships (and what must not)

`spec.files` is an explicit allow-list, never `git ls-files`:

```
lib/**/*.rb
bin/*
tools/**/*
config/policy.json
config/.env.example
README.md
LICENSE              # only when present
```

Everything else in the checkout stays out of the gem, by omission:

| Excluded | Why |
| --- | --- |
| `config/.env`, `config/.env.local`, `.env` | live provider API keys — secret |
| `runes.db`, `runes.db-*` | local preferences/runtime state |
| `log/`, `tmp/`, `workspace/` | local runtime state and tool side-effects |
| `ruby.wasm` (~35 MB), `*.wasm` | large vendored binary, not source |
| `docs/epics/`, `docs/missions/` | generated, LLM-influenced artifacts |
| `runes_observer/` | separate observatory app (see below) |
| `Gemfile`, `Gemfile.lock`, `test/`, `docs/` | development-only |

Verify the built list before publishing:

```sh
gem build runes.gemspec --output /tmp/runes.gem
ruby -rrubygems/package -e 'puts Gem::Package.new(ARGV[0]).spec.files' /tmp/runes.gem
```

`test/packaging_test.rb` asserts the same allow-list invariants, so a
regression fails CI rather than leaking a key into a release.

The seven executables installed with the gem (`bindir = "bin"`) are:

```
runes  runes-daemon  runes-client  runes-replay  runes-mcp  runes-acl  runes-workflow
```

The gemspec selects only those that exist on disk, so removing/renaming a
script cannot break `gem build`; `test/packaging_test.rb` asserts that `bin/`
and `spec.executables` agree, which is what caught `runes-acl` and
`runes-workflow` being on disk but absent from the gem.

## Runtime dependencies

Hard dependencies, because `require "runes"` loads them:

* `mqtt ~> 0.7` — MQTT transport
* `sqlite3 >= 2.1` — preferences/state database
* `dotenv ~> 3.1` — `config/.env`

## `wasmtime` is optional

`wasmtime` is **not** a gem dependency. It powers the real WASM sandbox for
untrusted tools (`lib/runes/wasm/vm_manager.rb`) and is needed by
`lib/runes/core/dispatcher.rb`. Install it only where you need that isolation:

```sh
gem install wasmtime        # or: bundle add wasmtime
```

Without it, `require "runes"` still succeeds: the two requires that pull
`wasmtime` in are wrapped in a narrow `rescue LoadError` that re-raises any
other failure and warns clearly. The trade-off is explicit:

* `Runes::WASM::VMManager` is unavailable, so tools fall back to the mock
  backend (`:auto` already prefers the real backend and degrades to mock), and
* `Runes::Core::Dispatcher` is not defined, because its own top-of-file require
  of `vm_manager` aborts before the class body runs. Code that needs the
  dispatcher must install `wasmtime`.

`test/packaging_test.rb` proves this in a child process by shadowing the gem
with a `wasmtime.rb` that raises `LoadError` (nothing is uninstalled).

## LLM provider-adapter seam

`Runes::Core::LLMClient` remains the default router and is unchanged. The seam
lives in `lib/runes/llm.rb`:

```ruby
Runes::LLM.adapter                      # Core::LLMClient (default)
Runes::LLM.adapter(settings)            # same, with settings

ENV['RUNES_LLM_ADAPTER'] = 'ruby_llm'   # community github.com/crmne/ruby_llm
Runes::LLM.adapter(settings)            # -> LLM::RubyLLMAdapter

Runes::LLM.register(:mine, MyAdapter)   # embedder-provided adapter
ENV['RUNES_LLM_ADAPTER'] = 'mine'
```

Selection is read at call time, so it is per-call and test-friendly. Unknown
names raise `Runes::LLM::AdapterUnavailable` naming the env var and the
registered adapters. If an adapter class defines `.available?` and it returns
false, selection raises `AdapterUnavailable` naming the missing gem and the env
var instead of a bare `LoadError`.

### `ruby_llm` adapter

`lib/runes/llm/ruby_llm_adapter.rb` wraps `ruby_llm` behind the harness
surface the dispatcher already calls:

```ruby
#call(prompt, provider:, model:, variation:, tools:)
#chat(messages, system:, json:, variation:, tools:)
```

Both return `{ok:, mode:, content:/tool_calls:, raw:, provider:, model:,
usage:, finish_reason:}` or `{ok: false, error:}`. The gem is required lazily
inside `.available?`, so the adapter file loads — and the registry stays
usable — without `ruby_llm` installed.

To use it:

```sh
gem install ruby_llm            # 1.x or 2.x
export RUNES_LLM_ADAPTER=ruby_llm
```

Mapping notes (lossy by design):

* `tools:` — OpenAI-style schemas from `Runes::Core::LLMClient.builtin_schemas`
  become anonymous `RubyLLM::Tool` subclasses (`tool_name`, `description`,
  `parameters`). Response tool calls are mapped back to the harness
  `tool_calls:` shape. The adapter requests one completion with `Chat#generate`
  and never executes tools — the harness does that — so a tool's `execute` is a
  loud error if it is ever reached.
* `variation:` — temperature (`high|max` 0.7, `balanced` 0.4, `low` 0.2) and,
  where the model supports it, extended-thinking effort (`max`→`:max`,
  `high`→`:high`). Unsupported knobs are dropped with a rescue, not fatal.
* `json: true` — **not** translated. `ruby_llm` expresses structured output
  with `with_schema`; inventing a schema here would be wrong. The harness
  planner prompts already request strict JSON and `PlanParser` tolerates
  fences.
* Providers — `deepseek` uses `ruby_llm`'s built-in provider; every other
  registry entry (synthetic, cerebras) is OpenAI-compatible, so the adapter
  points `ruby_llm`'s `:openai` provider at the registry `base_url`/API key in
  a per-request `RubyLLM::Context` (no global config mutation). Unknown models
  are passed with `assume_model_exists: true`.

Because `ruby_llm` is not installed in this checkout, the seam tests assert
registry/default selection and the unavailable-gem error only; the live
provider path is untested here by design, and `ruby_llm` is deliberately not a
dependency.

## `runes_observer/` is not part of the gem

`runes_observer/` is a separate application (its own dependencies and entry
point) that watches the fabric. It is excluded from `spec.files` and is not
installed by the gem; deploy it from its own directory.

## Tests

```sh
cd /path/to/runic
bundle exec ruby -Ilib -Itest test/packaging_test.rb
```

Hermetic: no network, no broker, no database, no `ruby_llm`.
