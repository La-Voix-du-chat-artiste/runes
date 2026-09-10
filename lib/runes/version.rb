module Runes
  # Harness version. 0.3.0 is the transport-agnostic series: the MQTT fabric
  # is now one adapter behind Runes::Transport, work distribution uses
  # MQTT 5 shared subscriptions (or the in-process hub) instead of a
  # home-grown claim/lease protocol, and agent discovery speaks the
  # A2A-over-MQTT profile.
  VERSION = "0.3.0".freeze
end
