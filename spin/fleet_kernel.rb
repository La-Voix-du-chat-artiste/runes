# frozen_string_literal: true

# The compiled fleet runtime: a Spinel kernel with a baked fleet world.
#
# The world is baked at BUILD time by scripts/fleet_bake.rb (loaded with the
# real fail-closed loader on CRuby, rules' actions probed to data) into
# spin/baked_world.json. This entry reconstructs it in-guest — no Prism, no
# procs cross the compile boundary — and runs the engine over the in-process
# transport with one synthetic event, printing the journal. That is the
# whole loop a compiled fleet guest needs: world in, events in, journal out.
#
#   spinel spin/fleet_kernel.rb -o build/runes-fleet-kernel
#   ./build/runes-fleet-kernel fleet
#
# Under CRuby the same entry runs with the pure backends (parity check):
#   ruby spin/fleet_kernel_cruby.rb fleet   (see spin/kernel_cruby.rb pattern)

require_relative '../lib/runes/compat'
require_relative '../lib/runes/json_facade'
require_relative '../lib/runes/json_pure'
require_relative '../lib/runes/sha256_facade'
require_relative '../lib/runes/random_facade'
require_relative '../lib/runes/request_ledger'
require_relative '../lib/runes/telemetry'
require_relative '../lib/runes/transport/base'
require_relative '../lib/runes/transport/in_process'
require_relative '../lib/runes/fleet/load_error'
require_relative '../lib/runes/fleet/rule'
require_relative '../lib/runes/fleet/world'
require_relative '../lib/runes/fleet/engine'

Runes::Json.backend = Runes::JSONPure
Runes::SHA256.backend = Runes::SHA256::Pure

BAKED_WORLD = File.expand_path('baked_world.json', __dir__)

if ARGV[0] == 'fleet'
  begin
    baked = Runes::Json.parse(File.read(BAKED_WORLD))
    world = Runes::Fleet::World.from_baked_h(baked)
    puts "fleet-kernel: world=#{world.name} roles=#{world.roles.size} rules=#{world.rules.size} baked=true"

    hub = Runes::Transport::InProcess::Hub.new(name: "fleet-kernel")
    transport = Runes::Transport::InProcess.new(hub: hub)
    transport.connect
    engine = Runes::Fleet::Engine.new(world, transport: transport)
    engine.start

    # One synthetic event on the first channel a rule listens to.
    # NOTE: block form, not map(&:source) — spinel miscompiles a top-level
    # symbol-to-proc map once engine.rb is in the image.
    channel_id = world.rules.select { |r| r.source_kind == :channel }.map { |r| r.source }.first
    if channel_id
      topic = world.channels.fetch(channel_id).topic
      transport.publish(topic, Runes::Json.generate("name" => "kernel", "score" => 1.0, "email" => "ada@example.fr"))
    end
    engine.stop

    entries = engine.journal.reject { |e| e["kind"] == "fleet_boot" }
    puts "fleet-kernel: journal entries=#{entries.size}"
    entries.first(5).each { |e| puts "  #{Runes::Json.generate(e)[0, 160]}" }
    if entries.empty?
      warn 'fleet-kernel: FAILED — no rule fired from the baked world'
      exit 1
    end
    puts 'FLEET KERNEL OK'
    exit 0
  rescue StandardError => e
    warn "fleet-kernel error: #{e.class}: #{e.message}"
    exit 1
  end
end

warn "usage: runes-fleet-kernel fleet"
exit 2
