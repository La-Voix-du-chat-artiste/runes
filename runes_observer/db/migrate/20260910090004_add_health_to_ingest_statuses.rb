class AddHealthToIngestStatuses < ActiveRecord::Migration[8.1]
  # "Connected" is not the question an operator has; *"is this feed
  # trustworthy right now?"* is (doc5.md O0.5). Two numbers answer it that the
  # row could not: how often the transport had to be rebuilt, and how stale
  # the newest packet's own clock is compared with when we stored it.
  #
  # `last_lag_ms` is nil when the publisher sent no clock at all (most raw
  # fabric traffic has none) — nil is honest, 0 would be a lie.
  def change
    add_column :ingest_statuses, :reconnects, :integer, null: false, default: 0
    add_column :ingest_statuses, :last_lag_ms, :integer
  end
end
