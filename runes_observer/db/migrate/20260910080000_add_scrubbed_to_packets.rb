class AddScrubbedToPackets < ActiveRecord::Migration[8.1]
  def change
    # MQTT payloads are arbitrary bytes. The recorder force-encodes every
    # payload to UTF-8 and scrubs invalid sequences before the sqlite3 bind;
    # this flag records when that lossy repair actually happened.
    add_column :packets, :scrubbed, :boolean, null: false, default: false
  end
end
