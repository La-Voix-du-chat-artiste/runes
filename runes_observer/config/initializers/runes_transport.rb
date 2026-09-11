# The observatory subscribes to the fabric through the harness's own
# transport seam (doc5.md O0.1) instead of owning an MQTT client:
#
#   * it sees MQTT 5 properties (`response_topic`, `correlation_id`,
#     `user_properties`), which the `mqtt` 0.7 client cannot carry at all,
#     so an A2A request/reply is reconstructable from what was stored;
#   * it is the strongest dogfood of `Runes::Transport` — the observer reads
#     the bus exactly the way the fleet writes it;
#   * `RUNES_TRANSPORT=inproc` gives a broker-free observatory: no mosquitto,
#     no ports, no network, which is what makes `FabricIngestTest` a real
#     ingest test rather than a fake-client test.
#
# The harness lives beside this app in the same checkout. The observer
# deliberately keeps NO gem dependency on it: `runes` declares `mqtt ~> 0.7`
# as a runtime dependency, and the observatory must not pin (or be pinned
# by) the client its own transport may or may not choose to use. Putting the
# harness's `lib` on the load path is the whole coupling, and
# `RUNES_HARNESS_LIB` overrides it for a gem-installed harness.
harness_lib = ENV.fetch("RUNES_HARNESS_LIB") do
  File.expand_path("../../../lib", __dir__)
end

if File.directory?(harness_lib) && !$LOAD_PATH.include?(harness_lib)
  $LOAD_PATH.unshift(harness_lib)
end

begin
  require "runes/transport"
  # Signature state is the other half of "who published this" (doc5.md O0.3):
  # the transport tells us what arrived, Runes::Security tells us whether the
  # envelope is backed by a key we trust. Only stdlib OpenSSL, so this cannot
  # pull a client library in.
  require "runes/security"
rescue LoadError => e
  # Not fatal: the web UI must still boot without the harness (it is
  # read-only over the database). `FabricIngest` fails loudly if it is
  # started without a transport, which is the process that actually needs it.
  Rails.logger.warn("[observer] Runes::Transport/Security unavailable (#{e.class}: #{e.message}); " \
                    "ingest needs a harness checkout at #{harness_lib} or RUNES_HARNESS_LIB")
end
