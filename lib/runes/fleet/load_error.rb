# frozen_string_literal: true

module Runes
  module Fleet
    # Reserved words (spec §13): parsed past the Walker so the builders can
    # reject them with the precise "reserved for v0.2" error. They live here
    # because every binding that evaluates fleet code needs them — the
    # builders AND the rule context (`spawn` collides with Kernel#spawn, so
    # it must be intercepted as a real method, not left to method_missing).
    RESERVED = {
      "spawn" => "process orchestration stays outside the DSL (spec §5.4)",
      "cell" => "mutable cells are v0.2 (spec §4.5/§14.3)",
      "interval" => "dynamic schedules stay in host code — use cron: (spec §4.6)"
    }.freeze

    # Every load-time failure raises this (spec FLEET_DSL.md §10, principle
    # P3): a fleet file that fails analysis aborts with ZERO partial world —
    # no transport subscriptions and no guard grants are left behind. Later
    # phases add SchemaError / GuardError / ActionError for run-time
    # refusals; a bad file is always THIS class.
    class LoadError < StandardError; end
  end
end
