# doc5.md O1.5 — detectors that run in the ingest process and turn derived
# findings into Alert rows. No job runner: call .call after each ingest batch
# (and from the /alerts page on demand). Dedupe is by (kind, subject) via
# Alert.record.
#
# Detectors shipped here (the two whose inputs already exist):
#   impersonation     one agent_id under two keys, or a key the trust store
#                     does not hold for it (ImpersonationDetector, O0.3)
#   signature_failure a packet whose envelope failed verification
#                     (signature_state invalid/untrusted), grouped by agent
class AlertDetector
  SIGNATURE_FAILURE_STATES = %w[invalid untrusted].freeze

  class << self
    def call(scope: Packet.all, at: Time.current)
      impersonation_alerts(scope, at) + signature_failure_alerts(scope, at)
    end

    private

    def impersonation_alerts(scope, at)
      ImpersonationDetector.call(scope: scope).map do |finding|
        Alert.record(
          kind: "impersonation",
          subject: finding.agent_id.to_s,
          severity: "error",
          details: { kind: finding.kind.to_s, fingerprints: finding.fingerprints,
                     trusted_fingerprint: finding.trusted_fingerprint,
                     description: finding.description },
          at: at
        )
      end
    end

    def signature_failure_alerts(scope, at)
      scope.where(signature_state: SIGNATURE_FAILURE_STATES)
           .group(:agent_id, :signature_state).count
           .map do |(agent_id, state), count|
        next if agent_id.nil?

        Alert.record(
          kind: "signature_failure",
          subject: agent_id.to_s,
          severity: "warn",
          details: { signature_state: state, packets: count },
          at: at,
          increment: count
        )
      end.compact
    end
  end
end
