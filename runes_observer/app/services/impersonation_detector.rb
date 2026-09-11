# The single most interesting security event on a shared broker: one
# `agent_id` publishing under more than one key (doc5.md O0.3).
#
# Two shapes, both derived from stored packets rather than from in-process
# state, so they survive a restart and can be asked of history:
#
#   split identity   the same `agent_id` has been seen with two different
#                    fingerprints. Either a key was rotated without the fleet
#                    knowing, or someone is publishing as that agent.
#   wrong key        the fingerprint on a packet is not the one the trust store
#                    holds for the agent the payload claims to be. A valid
#                    signature by the *wrong* key is exactly what a name is
#                    worth without this check.
#
# The observer only reports; nothing here blocks traffic.
class ImpersonationDetector
  Finding = Struct.new(:agent_id, :fingerprints, :trusted_fingerprint, :packets,
                       :first_seen, :last_seen, :kind, keyword_init: true) do
    def description
      case kind
      when :split_identity
        "#{agent_id} published under #{fingerprints.size} different keys"
      when :wrong_key
        "#{agent_id} published under a key the trust store does not hold for it"
      end
    end
  end

  class << self
    # @param scope [ActiveRecord::Relation] packets to consider
    # @param store [Runes::Security::TrustStore, nil] trust store (lazily built)
    def call(scope: Packet.where.not(key_fingerprint: nil), store: nil)
      store ||= ObserverSignature.trust_store
      seen = collect(scope)
      findings = []

      seen.each do |agent_id, prints|
        trusted = store.entry_for(agent_id)&.fingerprint
        if prints.size > 1
          findings << build(agent_id, prints, trusted, :split_identity)
        elsif trusted && prints.keys != [trusted]
          findings << build(agent_id, prints, trusted, :wrong_key)
        end
      end

      findings.sort_by { |f| -f.packets }
    end

    def any?(**options)
      call(**options).any?
    end

    private

    # { agent_id => { fingerprint => { packets:, first_seen:, last_seen: } } }
    def collect(scope)
      counts = scope.group(:agent_id, :key_fingerprint).count
      bounds = scope.group(:agent_id, :key_fingerprint).minimum(:occurred_at)
      latest = scope.group(:agent_id, :key_fingerprint).maximum(:occurred_at)

      counts.each_with_object({}) do |((agent_id, fingerprint), count), out|
        next if agent_id.blank? || fingerprint.blank?

        (out[agent_id] ||= {})[fingerprint] = { packets: count,
                                                first_seen: bounds[[agent_id, fingerprint]],
                                                last_seen: latest[[agent_id, fingerprint]] }
      end
    end

    def build(agent_id, prints, trusted, kind)
      Finding.new(agent_id: agent_id,
                  fingerprints: prints.keys.sort,
                  trusted_fingerprint: trusted,
                  packets: prints.values.sum { |v| v[:packets] },
                  first_seen: prints.values.map { |v| v[:first_seen] }.compact.min,
                  last_seen: prints.values.map { |v| v[:last_seen] }.compact.max,
                  kind: kind)
    end
  end
end
