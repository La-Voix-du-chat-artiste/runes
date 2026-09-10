class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents do |t|
      t.string :agent_id, null: false
      t.string :name
      t.string :kind
      t.string :version
      t.string :workspace
      t.text :tools
      t.string :state, null: false, default: "unknown"
      t.text :card
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :ended_at
      t.integer :packet_count, null: false, default: 0

      t.timestamps
    end

    add_index :agents, :agent_id, unique: true
    add_index :agents, :state
    add_index :agents, :last_seen_at
  end
end
