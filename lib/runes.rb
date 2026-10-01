# frozen_string_literal: true

# Public entry point for the `runes` gem.
#
# Loading this file must stay dependency-light: no broker connection, no
# database, no network. The only optional dependency is `wasmtime`, which
# the WASM sandbox needs; it is not a gemspec runtime dependency, so the
# requires that transitively pull it in are guarded (see GEM_PACKAGING.md).
require_relative 'runes/compat'
require_relative 'runes/json_facade'
require_relative 'runes/sha256_facade'
require_relative 'runes/random_facade'
# CRuby backends for the facades (stdlib JSON / OpenSSL / SecureRandom). The
# Spinel kernel entry wires the pure backends instead and never loads this.
require_relative 'runes/backends/cruby'
require_relative 'runes/telemetry'
require_relative 'runes/guard_telemetry'
require_relative 'runes/guard_telemetry_sink'
require_relative 'runes/request_ledger'
require_relative 'runes/kanban'
require_relative 'runes/doc_store'
require_relative 'runes/index'
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
# settings.rb defaults to SQLite when the gem is loadable (see the
# DEFAULT_SETTINGS_STORE resolution there); the explicit assignment is only
# a belt-and-braces harness preference.
require_relative 'runes/core/settings_sqlite'
Runes::Core::Settings.store_class = Runes::Core::SettingsStore::SQLite
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

# The Fleet DSL (0.4.0): the declarative world layer, loaded through a
# restricted-subset Prism walker (docs/FLEET_DSL.md). prism ships as a
# default gem on modern Rubies and is a declared gemspec dependency, so
# the require stays unguarded like the other core seams.
require_relative 'runes/fleet'
