class CreateConnectors < ActiveRecord::Migration[8.1]
  # docs/WORKSPACE_PLAN.md slice 2B: named MQTT connector profiles. Exactly one
  # may be active; activating bumps ingest_statuses.connector_epoch, which the
  # ingest process polls to rebuild its transport. Secrets are never stored:
  # password_env names the environment variable holding the password.
  def change
    create_table :connectors do |t|
      t.string :name, null: false
      t.string :host, null: false
      t.integer :port, null: false, default: 1883
      t.string :transport, null: false, default: "auto"
      t.boolean :tls, null: false, default: false
      t.string :client_id
      t.string :username
      t.string :password_env
      t.boolean :active, null: false, default: false
      t.datetime :last_probe_at
      t.string :last_probe_state
      t.text :last_probe_detail
      t.timestamps
    end
    add_index :connectors, :name, unique: true
    add_index :connectors, :active
  end
end
