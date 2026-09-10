class CreatePackets < ActiveRecord::Migration[8.1]
  def change
    create_table :packets do |t|
      t.string :topic, null: false
      t.text :payload
      t.integer :payload_bytes, null: false, default: 0
      t.boolean :truncated, null: false, default: false
      t.string :agent_id
      t.string :request_id
      t.string :lease_id
      t.string :kind, null: false, default: "other"
      t.string :event
      t.string :tool
      t.datetime :occurred_at, null: false
      t.datetime :received_at, null: false

      t.timestamps
    end

    add_index :packets, :occurred_at
    add_index :packets, :agent_id
    add_index :packets, :request_id
    add_index :packets, :lease_id
    add_index :packets, :kind
    add_index :packets, :topic
    add_index :packets, %i[agent_id id]
    add_index :packets, %i[request_id id]
    add_index :packets, %i[lease_id id]
  end
end
