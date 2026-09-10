# Phase 16 deleted the claim/lease protocol: the harness publishes no claim
# or started topics and no `runes/sessions/<lease>/…` space any more. The
# observer's lease vocabulary was therefore dead — no live traffic could
# populate it — so the column, its indexes and the dead kinds go with it.
class RemoveLeaseIdFromPackets < ActiveRecord::Migration[8.1]
  DEAD_KINDS = %w[claim started session_claim session_started].freeze

  def up
    execute("UPDATE packets SET kind = 'other' WHERE kind IN (#{DEAD_KINDS.map { |k| "'#{k}'" }.join(', ')})")
    remove_index :packets, column: %i[lease_id id]
    remove_index :packets, :lease_id
    remove_column :packets, :lease_id
  end

  def down
    add_column :packets, :lease_id, :string
    add_index :packets, :lease_id
    add_index :packets, %i[lease_id id]
  end
end
