class AddTransportToIngestStatuses < ActiveRecord::Migration[8.1]
  # "Is the observer watching the bus?" is not answered by host:port alone
  # once the ingest can run over inproc, mqtt5 or mqtt311: an inproc ingest
  # is connected to a hub inside its own process, and a UI that showed
  # "127.0.0.1:1883" for it would be lying. The dashboard shows this name.
  def change
    add_column :ingest_statuses, :transport, :string
  end
end
