#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate the L2 golden extracts for a fleet file (spec §8/§11):
#
#   ruby scripts/fleet_golden.rb examples/prospection.fleet.rb \
#        test/fixtures/fleet/prospection.golden.json
#
# The conformance suite (test/fleet_conformance_test.rb) diffs the live
# extracts against this file; run this script only when the fleet file
# changed INTENTIONALLY, and commit both together.

require_relative "../lib/runes"
require "json"

fleet_path, golden_path = ARGV
abort "usage: fleet_golden.rb FLEET_FILE GOLDEN_JSON" unless fleet_path && golden_path

world = Runes::Fleet.load_file(fleet_path)
golden = {
  "_comment" => "L2 conformance extract for #{fleet_path} — regenerate with: " \
                "ruby scripts/fleet_golden.rb #{fleet_path} #{golden_path}",
  "fleet" => world.name,
  "fingerprint" => world.fingerprint,
  "policy_extract" => world.policy_extract,
  "acl_extract" => world.acl_extract,
  "topology" => world.topology
}
File.write(golden_path, JSON.pretty_generate(golden) + "\n")
puts "golden #{golden_path}: fleet=#{world.name} fingerprint=#{world.fingerprint[0, 12]}…"
