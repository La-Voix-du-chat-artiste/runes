# Manual live check of doc5.md O2.3: publish one guard refusal and confirm the
# observatory stored it and the security page can count it.
#
#   # with the observatory ingest attached to the same broker:
#   ruby scripts/guard_denial_probe.rb
#
# Prints the tool/action/resource it published, so the security page (or
# `Packet.where(kind: "guard_denied")`) can be checked against it.
require "json"
require "securerandom"
require_relative "../lib/runes/guard_telemetry"

TAG = SecureRandom.hex(4)
AGENT = ENV.fetch("RUNES_PROBE_AGENT", "probe-agent")
TOOL = ENV.fetch("RUNES_PROBE_TOOL", "run_command")
ACTION = ENV.fetch("RUNES_PROBE_ACTION", "exec")
RESOURCE = ENV.fetch("RUNES_PROBE_RESOURCE", "rm -rf /tmp/probe-#{TAG}")

sink = Runes::GuardTelemetry.build_sink(ENV.fetch("RUNES_TRANSPORT", "mqtt5"))
abort "guard denial probe: could not build a sink" if sink.nil?

Runes::GuardTelemetry.sink = sink
decision = Runes::GuardTelemetry.record(tool: TOOL, action: ACTION, resource: RESOURCE,
                                       agent: AGENT, phase: "tool")
puts JSON.generate(decision)
