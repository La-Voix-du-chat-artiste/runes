require "json"

module Runes
  # Message-level security: per-agent Ed25519 identities, signed JSON
  # envelopes and a trust store of peer public keys. The in-process
  # capability guard protects *what a tool may do*; this protects *who may
  # ask*, which is what a shared broker needs.
  #
  # The error classes live with their subject (IdentityError in identity.rb,
  # EnvelopeError/VerificationError in envelope.rb); this file only ties the
  # namespace together.
  module Security
    class Error < StandardError; end
  end
end

require_relative "security/identity"
require_relative "security/envelope"
require_relative "security/trust_store"
require_relative "security/credentials"
require_relative "security/command_policy"
require_relative "security/rpc_auth"
