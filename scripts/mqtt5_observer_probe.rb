# Manual live check of doc5.md O0.1 and O0.3: publish one A2A-shaped message
# with real MQTT 5 properties, optionally signed with an Ed25519 identity, and
# confirm the observatory ingested the properties and the signature verdict.
#
#   ruby scripts/mqtt5_observer_probe.rb            # prints the correlation tag
#
#   # signed (doc5.md O0.3): generate a key, trust it, publish a signed envelope
#   RUNES_PROBE_SIGN=1 RUNES_PROBE_KEY_DIR=/tmp/probe-keys \
#     RUNES_PROBE_TRUST_DIR=/tmp/probe-trust ruby scripts/mqtt5_observer_probe.rb
#
# Expects the running observatory ingest to be attached to the same broker
# with RUNES_TRANSPORT=mqtt5 — and, for the signed case, started with
# RUNES_OBSERVER_TRUST_DIR pointing at RUNES_PROBE_TRUST_DIR and the public key
# already written there (run this script with RUNES_PROBE_SETUP_ONLY=1 first).
require "json"
require "securerandom"
require "fileutils"
require_relative "../lib/runes/transport/mqtt5"

TAG = SecureRandom.hex(4)
AGENT = ENV.fetch("RUNES_PROBE_AGENT", "probe-agent")
KEY_DIR = ENV.fetch("RUNES_PROBE_KEY_DIR", "/tmp/runes-probe-keys")

payload = { "method" => "tasks/send", "params" => { "tag" => TAG }, "agent" => AGENT }

if ENV["RUNES_PROBE_SIGN"] == "1"
  require_relative "../lib/runes/security"
  identity = Runes::Security::Identity.load_or_create(agent_id: AGENT, dir: KEY_DIR)

  trust_dir = ENV["RUNES_PROBE_TRUST_DIR"]
  if trust_dir
    FileUtils.mkdir_p(trust_dir)
    File.write(File.join(trust_dir, "#{AGENT}.pem"), identity.public_key_pem)
  end
  payload = Runes::Security::Envelope.sign(payload, identity)
  warn "signed as #{AGENT} kid=#{identity.fingerprint}"
  if ENV["RUNES_PROBE_SETUP_ONLY"] == "1"
    puts "trust dir ready: #{trust_dir}"
    exit 0
  end
end

transport = Runes::Transport::MQTT5.new(host: ENV.fetch("RUNES_MQTT_HOST", "127.0.0.1"),
                                        port: ENV.fetch("RUNES_MQTT_PORT", "1883").to_i,
                                        client_id: "observer-probe-#{TAG}")
transport.connect
transport.publish("runes/a2a/tasks/#{AGENT}",
                  JSON.generate(payload),
                  qos: 1,
                  properties: { response_topic: "runes/a2a/replies/#{TAG}",
                                correlation_id: TAG,
                                user_properties: { "a2a-status" => "working", "probe-tag" => TAG } })
sleep 0.3
transport.disconnect
puts TAG
