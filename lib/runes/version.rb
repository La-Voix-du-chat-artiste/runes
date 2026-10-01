module Runes
  # Harness version. 0.4.0 is the fleet layer: `.fleet.rb` files declare a
  # world (agents, channels, routes, facts, schedules) and rules (`on …
  # do |e|`) in a restricted, statically analyzable Ruby subset, loaded
  # fail-closed through a Prism whitelist walker (docs/FLEET_DSL.md). Rules
  # run on a hermetic engine — declaration-order firing, deterministic
  # request ids through the RequestLedger, dead-letter on fan-out — wired
  # into the daemon via `--fleet`, with policy/ACL/topology extracts
  # golden-tested at L2 conformance. The Spinel kernel of 0.3.0 is
  # unchanged underneath.
  VERSION = "0.4.0".freeze
end
