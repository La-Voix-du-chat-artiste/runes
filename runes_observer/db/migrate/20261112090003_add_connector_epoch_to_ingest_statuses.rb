class AddConnectorEpochToIngestStatuses < ActiveRecord::Migration[8.1]
  # Bumped by ConnectorManager.activate!; FabricIngest polls it and rebuilds
  # its transport when it changes, so switching connectors from the UI takes
  # effect without restarting the ingest process.
  def change
    add_column :ingest_statuses, :connector_epoch, :integer, null: false, default: 0
  end
end
