# frozen_string_literal: true

require_relative 'orchestration/violation'
require_relative 'orchestration/receipt'
require_relative 'orchestration/guards'
require_relative 'orchestration/cumulative'
require_relative 'orchestration/shape'
require_relative 'orchestration/team_plan'
require_relative 'orchestration/conductor'

module Runes
  # The cumulative small-model harness: a ledger, code guards, and a role
  # loop. This is a library seam, not a new rune verb.
  module Orchestration
  end
end
