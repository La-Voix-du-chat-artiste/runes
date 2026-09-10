class AddTransportMetadataToPackets < ActiveRecord::Migration[8.1]
  # The observer used to see the fabric through `mqtt` 0.7, which speaks
  # MQTT 3.1.1: topic, payload and a retain flag, and nothing else. The
  # fleet, meanwhile, routes its replies with MQTT 5 properties. Ingest now
  # goes through `Runes::Transport` (doc5.md O0.1), whose `Message` carries
  # exactly these fields, so what the observer stores is the transport's own
  # view of a packet rather than a lossy second reading of it (doc5.md O0.2).
  #
  # `correlation_id` is indexed because that is the join key for
  # request/reply reconstruction: it is the only identifier that survives a
  # payload the observer could not parse.
  def change
    add_column :packets, :qos, :integer
    add_column :packets, :retain, :boolean
    add_column :packets, :correlation_id, :string
    add_column :packets, :response_topic, :string
    add_column :packets, :user_properties, :text
    add_index :packets, :correlation_id
  end
end
