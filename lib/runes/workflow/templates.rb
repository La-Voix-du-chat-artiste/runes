# frozen_string_literal: true

# CRuby-only extension: ERB template lookup for workflow params
# (docs/spinel/spec-tier-c.md §C3). Loaded by lib/runes/backends/cruby.rb.
# A compiled kernel raises NoMethodError on `template` — inline the text.
require 'erb'
require 'pathname'

require_relative 'workflow_params'

module Runes
  # Mixed into WorkflowParamAccessors (CRuby only). Depends on
  # `workflow_context` being provided by the includer.
  module WorkflowParamTemplates
    # ERB template lookup, matching Roast's search order:
    # workflow dir, workflow dir/{prompts,templates}, current dir,
    # current dir/{prompts,templates}; each with "", ".erb", ".md.erb".
    def template(path, args = {})
      path = Pathname.new(path) unless path.is_a?(Pathname)
      candidates = []
      candidates << path if path.absolute?

      bases = [Pathname.new(workflow_context.workflow_dir.to_s), Pathname.pwd]
      bases.each do |base|
        [base, base / 'prompts', base / 'templates'].each do |dir|
          candidates << dir / path
          candidates << Pathname.new("#{dir / path}.erb")
          candidates << Pathname.new("#{dir / path}.md.erb")
        end
      end

      begin
        expanded = Pathname.new(File.expand_path(path.to_s))
        candidates << expanded
        candidates << Pathname.new("#{expanded}.erb")
        candidates << Pathname.new("#{expanded}.md.erb")
      rescue ArgumentError
        # `~unknown_user/...` cannot be expanded; the other candidates stand.
      end

      resolved = candidates.find(&:exist?)
      unless resolved
        raise Runes::CogInputContext::ContextNotFoundError, "The file '#{path}' could not be found"
      end

      ERB.new(resolved.read).result_with_hash(args)
    end
  end
end

# Wire it in: the accessors module is included/extended across the engine.
module Runes
  module WorkflowParamAccessors
    include Runes::WorkflowParamTemplates
  end
end
