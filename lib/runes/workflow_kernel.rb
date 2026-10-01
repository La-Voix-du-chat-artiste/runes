# frozen_string_literal: true

# Kernel-safe workflow engine entry (Tier C3, docs/spinel/spec-tier-c.md):
# the subset-swept engine plus the five compiled-safe runes (`cmd`, `ruby`,
# `call`, `map`, `repeat`). `chat`/`agent` and the dynamic conveniences
# (`Config.field`, ruby method_missing delegation, ERB templates, `use`)
# stay CRuby-only. The CRuby entry point is lib/runes/workflow.rb.
require_relative 'telemetry'
require_relative 'kanban'
require_relative 'doc_store'
require_relative 'index'
require_relative 'runtime'
require_relative 'rune'
require_relative 'workflow_policy'
require_relative 'workflow/errors'
require_relative 'workflow/util'
require_relative 'workflow/workflow_params'
require_relative 'workflow/task'
require_relative 'workflow/cog_input_context'
require_relative 'workflow/system_rune'
require_relative 'workflow/config_manager'
require_relative 'workflow/execution_manager'
require_relative 'workflow/workflow'
require_relative 'plugins/ruby'
require_relative 'plugins/cmd'
require_relative 'plugins/call'
require_relative 'plugins/map'
require_relative 'plugins/repeat'

module Runes
  class Workflow
    # The compiled kernel's built-in runes. The full seven live in
    # lib/runes/workflow.rb (CRuby entry); chat/agent need the LLM/process
    # shell and stay interpreted.
    KERNEL_RUNES = [
      Runes::Plugins::Ruby,
      Runes::Plugins::Cmd,
      Runes::Plugins::Call,
      Runes::Plugins::Map,
      Runes::Plugins::Repeat
    ].freeze

    class << self
      # (Re-)registers the kernel's built-in runes. Mirrors the CRuby
      # entry's register_builtin_runes! for the reduced verb set.
      def register_builtin_runes!
        KERNEL_RUNES.each do |rune_class|
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
