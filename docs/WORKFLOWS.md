# Workflows — Runes as plugins

Runes can run **structured AI workflows**: small Ruby files that chain
steps together, in the spirit of Shopify's [Roast](https://github.com/shopify/roast).
Roast calls these building blocks *cogs*; here they are **Runes** — because
this project is Runes, and because a rune is the unit you compose with.

## The idea: a Rune is a `:plugin`

`Runes::Plugin` is a tiny registry (`lib/runes/plugin.rb`): anything that
declares `plugin :name, kind: :rune` becomes available to the workflow DSL
under that name. `Runes::Rune` is the workflow-facing base class.

```ruby
class Runes::Plugins::Greet < Runes::Rune
  plugin :greet, description: "Say hello"

  class Input < Runes::Cog::Input
    attr_accessor :name

    def validate!
      raise InvalidInputError, "'name' is required" if name.nil?
    end

    def coerce(input_return_value)
      super
      @name = input_return_value.to_s
    end
  end

  class Output < Runes::Cog::Output
    attr_reader :text

    def initialize(text)
      super()
      @text = text
    end

    def raw_text = text
  end

  def execute(input) = Output.new("hello #{input.name}")
end
```

That is the whole extension story: register a plugin, and
`greet(:hi) { "world" }` works inside any workflow — no change to the DSL,
exactly how a DSH plugin adds a capability to the harness. (This exact
class is exercised by `test/plugin_test.rb`, so the documented contract is
the tested one.) The seven built-ins are themselves `:rune` plugins:

| Rune | Purpose | Output readers |
|---|---|---|
| `chat` | prompt a cloud LLM | `response`, `session` |
| `agent` | run a local coding agent CLI (Pi, Claude Code) with filesystem access | `response`, `session`, `stats` |
| `ruby` | run Ruby inside the workflow | `value` (+ method/hash delegation) |
| `cmd` | run a command (String, or argv Array) and capture output | `out`, `err`, `status`, `lines` |
| `map` | process a collection, serial or parallel | `iteration(i)`, `first`, `last` |
| `repeat` | iterate until a condition / budget is met | `value`, `iteration(i)`, `results` |
| `call` | invoke a named `execute(:scope)` block | `from(...)` to extract |

Inspect them at runtime:

```ruby
Runes::Plugin.names(kind: :rune)   # => [:agent, :call, :chat, :cmd, :map, :repeat, :ruby]
Runes::Plugin[:cmd]                # => Runes::Plugins::Cmd
```

## A workflow

```ruby
# analyze_codebase.rb
execute do
  cmd(:recent_changes) { "git diff --name-only HEAD~5..HEAD" }

  agent(:review) do
    files = cmd!(:recent_changes).lines
    <<~PROMPT
      Review these recently changed files for potential issues:
      #{files.join("\n")}

      Focus on security, performance, and maintainability.
    PROMPT
  end

  chat(:summary) do
    "Summarize this for non-technical stakeholders:\n\n#{agent!(:review).response}"
  end
end
```

Run it:

```bash
bin/runes-workflow execute analyze_codebase.rb              # every step
bin/runes-workflow execute analyze_codebase.rb chat_summary # one step
bin/runes-workflow --quiet execute analyze_codebase.rb      # silent on success
```

On success the runner prints the workflow's final output (text runes print
their text; anything else is inspected) and exits 0. A failing rune exits
1 with the error on stderr.

That file is the Roast README example (`execute` byte-for-byte; only a
comment header was added), and it ships as
`examples/analyze_codebase.rb` — the compatibility test reads that very
file, so the example in the docs and the artifact the suite proves cannot
drift apart.

## What "compatible" means (and does not)

Matched: the file/`instance_eval` model; `config`/`execute`/`use`; positional
step names with anonymous fallback; the block contract
`|my, scope_value, scope_index|` with `self` inside the rune's input context;
`X`/`X!`/`X?` output accessors and their exact error conditions;
`outputs`/`outputs!`; `from`/`collect`/`reduce`; `skip!`/`fail!`/`next!`/`break!`;
per-rune `config` scoping (`nil`/`:name`/`/regexp/`) with the documented
merge precedence; `async!`; the output reader names (`out`/`err`/`status`/
`response`/`value`/`iteration`/`results`); the provider configuration names
and environment variables.

Deliberate differences:

- **No `async` gem.** `async!` runs runes on Ruby threads, which preserves
  the observable semantics without a new dependency. The one place the
  difference shows: a thread that has already started cannot be cancelled,
  so `break!` only prevents iterations that have not started yet (Roast's
  `Async::Barrier` can cancel a task that is already running).
- **No Event/monitor system.** Roast streams progress through `Event`;
  here `show_stdout!`/`show_response!` write to `$stdout` directly. The
  observatory is the richer viewer.
- **No `ruby_llm` dependency.** `chat` keeps Roast's provider names,
  env vars and default models, but delegates the HTTP call to Runes'
  own router (DeepSeek/Synthetic/Cerebras/OpenAI-compatible), so the same
  workflow can run on whatever key you have. A `ruby_llm` backend is
  available through `RUNES_LLM_ADAPTER=ruby_llm`.
- **A Hash is not a `cmd` input.** Roast's `cmd` accepts a command String or
  an argv Array; returning anything else fails validation. Runes fails with
  the same error class but a message that names the actual mistake instead
  of the generic `'command' is required`.
- **Small, deliberate deltas (kept as-is).** Top-level `next!` is swallowed
  here (it ends the scope) where Roast re-raises; `Config#field` returns a
  stored `false` where Roast returns the default; `Config#merge` deep-dups
  both sides where Roast merges shallowly; `Ruby::Output#call(:key, x)`
  forwards the key (fixing a Roast bug that drops it); and
  `Map::Config#parallel(negative)` means "unlimited" in both, so its own
  negative check is unreachable.

### The guard, opt-in (doc5.md E5-6)

A workflow used to be a way *around* the capability guard: `cmd`, `agent` and
`ruby` execute without asking. They can ask now:

```bash
RUNES_WORKFLOW_POLICY=config/workflow-policy.json \
  bin/runes-workflow execute examples/analyze_codebase.rb
```

The policy is the same shape as the tool guard, keyed by **rune name**:

```json
{
  "tools": {
    "cmd":   { "exec":    ["echo hello", "git diff --name-only HEAD~5..HEAD"] },
    "agent": { "exec":    ["pi --mode json -p"] },
    "ruby":  { "execute": ["#"] }
  }
}
```

Three things worth knowing before you turn it on:

- **It is off by default**, and must stay that way for the layer to be Roast
  compatible: a default-deny policy would break every unmodified workflow file.
- **A pattern matches the command TEXT**, with the guard's existing semantics:
  an exact string, or `#` to allow everything. There are no globs — so a narrow
  policy is genuinely narrow, and `"cmd": { "exec": ["#"] }` is the honest way to
  say "I trust this file".
- **A policy that cannot be parsed fails closed** (the guard refuses everything
  rather than silently allowing), and the runner says so on stderr.

What is still *not* guarded: a rune does not confine paths itself — the guard
decides, and `cmd` runs through the argv path so a policy that allows a
command allows that entire command. Treat the policy as the boundary, and keep
`RUNES_WORKFLOW_POLICY` set wherever a workflow is not written by you.

