# frozen_string_literal: true

module Runes
  module Fleet
    # Every load-time failure raises this (spec FLEET_DSL.md §10, principle
    # P3): a fleet file that fails analysis aborts with ZERO partial world —
    # no transport subscriptions and no guard grants are left behind. Later
    # phases add SchemaError / GuardError / ActionError for run-time
    # refusals; a bad file is always THIS class.
    class LoadError < StandardError; end
  end
end
