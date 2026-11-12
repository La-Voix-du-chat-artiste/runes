#!/usr/bin/env ruby
# frozen_string_literal: true

# Bake a fleet file into pure data for the compiled fleet runtime:
# loads it with the real fail-closed loader (CRuby side), probes every
# rule's actions, and writes the world's baked hash as JSON. The Spinel
# kernel entry (spin/fleet_kernel.rb) embeds this file and reconstructs
# the world in-guest — no Prism, no procs cross the compile boundary.
#
#   ruby scripts/fleet_bake.rb examples/prospection.fleet.rb spin/baked_world.json
require 'json'
require 'fileutils'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'runes/fleet'

src_path = ARGV[0] || File.expand_path('../examples/prospection.fleet.rb', __dir__)
out_path = ARGV[1] || File.expand_path('../spin/baked_world.json', __dir__)

baked = Runes::Fleet.bake_file(src_path)
FileUtils.mkdir_p(File.dirname(out_path))
File.write(out_path, JSON.pretty_generate(baked) + "\n")
puts "baked #{src_path} -> #{out_path} (#{baked['rules'].size} rules, #{baked['roles'].size} roles, fingerprint of source world)"
