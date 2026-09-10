# Manual live check of doc5.md O0.1: publish one A2A-shaped message with real
# MQTT 5 properties and confirm the observatory ingested them.
#
#   ruby scripts/mqtt5_observer_probe.rb      # prints the correlation tag
#
# Expects the running observatory ingest to be attached to the same broker
# with RUNES_TRANSPORT=mqtt5.
require "json"
require "securerandom"
require_relative "../lib/runes/transport/mqtt5"

TAG = SecureRandom.hex(4)
transport = Runes::Transport::MQTT5.new(host: ENV.fetch("RUNES_MQTT_HOST", "127.0.0.1"),
                                        port: ENV.fetch("RUNES_MQTT_PORT", "1883").to_i,
                                        client_id: "observer-probe-#{TAG}")
transport.connect
transport.publish("runes/a2a/tasks/probe-agent",
                  JSON.generate("method" => "tasks/send", "params" => { "tag" => TAG }),
                  qos: 1,
                  properties: { response_topic: "runes/a2a/replies/#{TAG}",
                                correlation_id: TAG,
                                user_properties: { "a2a-status" => "working", "probe-tag" => TAG } })
sleep 0.3
transport.disconnect
puts TAG
