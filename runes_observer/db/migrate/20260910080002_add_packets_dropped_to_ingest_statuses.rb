class AddPacketsDroppedToIngestStatuses < ActiveRecord::Migration[8.1]
  def change
    # A message the ingest saw but could not store (bad encoding, DB
    # contention, …) must be visible: a silent drop turns a partial outage
    # into an invisible one.
    add_column :ingest_statuses, :packets_dropped, :integer, null: false, default: 0
  end
end
