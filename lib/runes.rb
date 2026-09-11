# frozen_string_literal: true

# Public entry point for the `runes` gem.
#
# Loading this file must stay dependency-light: no broker connection, no
# database, no network. The only optional dependency is `wasmtime`, which
# the WASM sandbox needs; it is not a gemspec runtime dependency, so the
# requires that transitively pull it in are guarded (see GEM_PACKAGING.md).
require_relative 'runes/telemetry'
require_relative 'runes/guard_telemetry'
require_relative 'runes/transport'
# The `mqtt` gem is a gemspec runtime dependency, so for a gem install this
# always resolves. It is guarded anyway for the embed case (a checkout put on
# the load path without the gem), where `Runes::Transport` must still be a
# *whole* module: mqtt5 and inproc need no client library at all.
begin
  require_relative 'runes/transport/mqtt311'
rescue LoadError
  nil
end
require_relative 'runes/a2a'
require_relative 'runes/core/settings'
require_relative 'runes/core/llm_client'
require_relative 'runes/core/plan_parser'
require_relative 'runes/core/tool_registry'
require_relative 'runes/llm'

# wasmtime is optional. `dispatcher.rb` requires `wasm/vm_manager` (which
# requires wasmtime) before it defines anything, so we have to guard the
# dispatcher require as well as vm_manager's own — otherwise a wasmtime-less
# install raises LoadError before the harness can boot at all. Swallow ONLY
# the missing-wasmtime LoadError; any other boot failure still propagates.
begin
  require_relative 'runes/core/dispatcher'
rescue LoadError => e
  raise unless e.path.to_s == 'wasmtime' || e.message.include?('wasmtime')

  warn "runes: optional 'wasmtime' gem is not installed — WASM sandbox disabled " \
       "and Runes::Core::Dispatcher unavailable. `gem install wasmtime` to enable them."
end

require_relative 'runes/capabilities/guard'

begin
  require_relative 'runes/wasm/vm_manager'
rescue LoadError => e
  raise unless e.path.to_s == 'wasmtime' || e.message.include?('wasmtime')

  warn "runes: optional 'wasmtime' gem is not installed — the real WASM backend is " \
       "unavailable and tools fall back to the mock backend. `gem install wasmtime` to enable it."
end

# The Roast-compatible workflow DSL: a `:rune` plugin per workflow verb.
require_relative 'runes/workflow'
