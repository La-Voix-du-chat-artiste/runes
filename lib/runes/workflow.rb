# frozen_string_literal: true

# Runes workflow engine: a Roast-compatible workflow DSL assembled from
# `:rune` plugins.
#
#   require "runes/workflow"
#
#   Runes::Workflow.from_file("workflow.rb", Runes::WorkflowParams.new)
#
# Every file here is stdlib-only: no `async`, no `ruby_llm`, no network at
# load time. `async!` runes run on Ruby Threads (see workflow/task.rb).
#
# Deliberate deviations from Roast (kept as-is; documented so they are not
# mistaken for bugs — see docs/WORKFLOWS.md "Deliberate differences"):
#   * top-level `next!` is swallowed here (it ends the scope); Roast re-raises.
#   * `Config#field` returns the stored `false` where Roast returns the
#     default for a falsy-but-present value.
#   * `Config#merge` deep-dups both sides; Roast's merge is shallow.
#   * `Ruby::Output#call(:key, x)` forwards the key (Roast drops it, a bug).
#   * `Map::Config#parallel(negative)` means "unlimited" in both, so its own
#     negative check is unreachable — kept for wire-compatibility.
#   * `cmd` does NOT inherit Roast's shell behaviour for a command String
#     (W5-1): Strings are shell-split and run as argv; `shell: true` opts in.
#   * `Workflow.from_file` deletes its tmpdir before returning (W5-13).
require_relative "telemetry"
# Workflow files reference these by name, and the engine is where a workflow's
# constants have to be available: the mission format, the content-addressed
# document store and the code index that a pipeline artifact needs.
require_relative "kanban"
require_relative "doc_store"
require_relative "index"
require_relative "rune"
require_relative "workflow_policy"
require_relative "command_runner"

require_relative "workflow/workflow_params"
require_relative "workflow/task"
require_relative "workflow/cog_input_context"
require_relative "workflow/system_rune"
require_relative "workflow/config_manager"
require_relative "workflow/execution_manager"
require_relative "workflow/workflow"

# Runes (a `:rune` plugin each; the plugin name is the DSL verb).
require_relative "plugins/ruby"
require_relative "plugins/cmd"
require_relative "plugins/chat"
require_relative "plugins/agent"
require_relative "plugins/call"
require_relative "plugins/map"
require_relative "plugins/repeat"

module Runes
  class Workflow
    # The engine's own runes, in the order they are loaded.
    BUILTIN_RUNES = [
      Runes::Plugins::Ruby,
      Runes::Plugins::Cmd,
      Runes::Plugins::Chat,
      Runes::Plugins::Agent,
      Runes::Plugins::Call,
      Runes::Plugins::Map,
      Runes::Plugins::Repeat
    ].freeze

    class << self
      # (Re-)registers the built-in runes. `Runes::Plugin.reset!` keeps
      # declared plugins, so this is normally a no-op; it exists so the engine
      # still works if something registered over a built-in or booted the
      # registry from scratch.
      def register_builtin_runes!
        BUILTIN_RUNES.each do |rune_class|
          next if Runes::Plugin.registered?(rune_class.plugin_name, kind: :rune)

          Runes::Plugin.register(
            rune_class,
            name: rune_class.plugin_name,
            kind: :rune,
            description: rune_class.plugin_description
          )
        end
      end
    end
  end
end

Runes::Workflow.register_builtin_runes!
