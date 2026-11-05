# frozen_string_literal: true

require_relative 'swarm/identity'
require_relative 'swarm/capacity'
require_relative 'swarm/decision'
require_relative 'swarm/model_family'
require_relative 'swarm/manifest'
require_relative 'swarm/registry'
require_relative 'swarm/envelope'
require_relative 'swarm/capacity_broker'
require_relative 'swarm/contract_guard'
require_relative 'swarm/checkpoint'

module Runes
  # The specialized small-model swarm: declared identity, explicit
  # capacities, and first-class decline/escalation.
  #
  # This is a library seam, not a new rune verb. The seven verbs are
  # unchanged; the conductor and benchmark build on these contracts.
  module Swarm
  end
end
