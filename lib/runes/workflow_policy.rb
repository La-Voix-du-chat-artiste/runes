# frozen_string_literal: true

require_relative "capabilities/guard"

module Runes
  # Opt-in capability policy for workflow runes (doc5.md E5-6).
  #
  # A separate top-level module rather than Runes::Workflow::Policy because
  # Runes::Workflow is a CLASS: opening it as a module first made the class
  # definition fail with "Workflow is not a class".
  module WorkflowPolicy
    #
    # The round-5 audit's standing gap: a workflow was a way *around* the
    # capability guard rather than through it, because `cmd`, `agent` and
    # `ruby` all execute without asking. This is the seam that lets them ask.
    #
    # It is OFF by default, deliberately. A default-deny policy would break
    # every unmodified Roast file — the whole point of the workflow layer — so
    # enabling it is an explicit act:
    #
    #   RUNES_WORKFLOW_POLICY=config/workflow-policy.json bin/runes-workflow execute w.rb
    #
    # or for an embedder:
    #
    #   Runes::Workflow::Policy.install("config/workflow-policy.json")
    #
    # The policy uses the same shape as the tool guard, keyed by RUNE name:
    #
    #   { "tools": { "cmd":   { "exec":    ["echo *", "git diff*"] },
    #                "agent": { "exec":    ["pi *"] },
    #                "ruby":  { "execute": ["*"] } } }
    #
    # The resource is the command TEXT (so patterns match literally, like the
    # dispatcher's `exec` rules), which is why the recommended starter policy
    # is narrow rather than `["*"]`.
      # Raised when a rune is refused. Deliberately a distinct class: a policy
      # refusal is an operational decision, not a bug in the workflow.
      class Denied < Runes::Error; end

      class << self
        attr_accessor :guard

        def enabled?
          !guard.nil?
        end

        # Install a guard from an explicit path or RUNES_WORKFLOW_POLICY.
        # Returns the guard, or nil when no policy is configured (the default).
        def install(policy_file = nil, fragments: [], env: ENV)
          file = policy_file.to_s.strip.empty? ? env["RUNES_WORKFLOW_POLICY"] : policy_file
          return reset! if file.to_s.strip.empty?

          self.guard = Runes::Capabilities::Guard.new(file, additional_fragments: Array(fragments))
        end

        def reset!
          self.guard = nil
        end

        # The one question the runes ask. Returns true when allowed; raises
        # Denied with a message that names what to change when it is not.
        def authorize!(rune:, action:, resource:, hint: nil)
          return true if guard.nil?

          return true if guard.allowed?(rune.to_s, action, resource)

          detail = guard.respond_to?(:policy_unreadable) && guard.policy_unreadable ?
                     "the configured policy could not be parsed, so nothing is allowed" :
                     "#{rune}(#{action}) is not permitted for #{resource.inspect}"
          raise Denied, "workflow policy refused #{detail}. " \
                        "Set RUNES_WORKFLOW_POLICY to a policy that allows it" \
                        "#{hint ? " (#{hint})" : ''}, or run without the policy."
        end

        # The guard the runes consult. Kept as an explicit accessor so a test
        # can install one without touching the environment.
        def describe
          return "off" if guard.nil?
          return "on (policy unreadable: fail-closed)" if guard.respond_to?(:policy_unreadable) && guard.policy_unreadable

          "on"
        end
      end
    end
end
