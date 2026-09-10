# frozen_string_literal: true

module Runes
  # Root of every error raised by the workflow engine. Kept separate from the
  # transport/core errors so an embedder can rescue workflow failures without
  # swallowing harness failures.
  class Error < StandardError; end

  # Raised from inside a rune's input block or `#execute` to steer the engine.
  # `Base` inherits directly from StandardError (matching Roast) so that the
  # rune lifecycle rescues can order `ControlFlow` ahead of `StandardError`.
  module ControlFlow
    class Base < StandardError; end

    # Terminate the rune, mark it skipped, do not fail the workflow.
    class SkipCog < Base; end

    # Terminate the rune and mark it failed. Re-raised (aborting the scope)
    # only when the rune's config has `abort_on_failure?` (the default).
    class FailCog < Base; end

    # Terminate the current loop iteration; the rune is marked skipped.
    class Next < Base; end

    # Terminate the loop; the rune is marked skipped. Swallowed by the
    # top-level executor (treated like `Next`).
    class Break < Base; end
  end

  # Parent of every error raised when resolving a rune's output.
  class CogOutputAccessError < Error; end

  # Raised for a name that no rune in the current scope ever used.
  class CogDoesNotExistError < CogOutputAccessError; end

  # Raised when a rune exists but has not finished running successfully yet.
  class CogNotYetRunError < CogOutputAccessError; end

  # Raised when a rune was skipped (`skip!`, `next!`, `break!`).
  class CogSkippedError < CogOutputAccessError; end

  # Raised when a rune failed.
  class CogFailedError < CogOutputAccessError; end

  # Raised when a rune was stopped (its scope was stopped before it ran).
  class CogStoppedError < CogOutputAccessError; end

  # Raised when two runes in one scope share a name.
  class RuneAlreadyDefinedError < Error; end

  # Raised when a run exceeds the workflow's deadline (W5-10). The deadline
  # is enforced by the execution manager before each rune and by `repeat`
  # between iterations.
  class WorkflowTimeoutError < Error; end
end
