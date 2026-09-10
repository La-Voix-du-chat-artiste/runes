class CreateIngestStatuses < ActiveRecord::Migration[8.1]
  def change
    create_table :ingest_statuses do |t|
      t.boolean :connected, null: false, default: false
      t.string :host
      t.integer :port
      t.datetime :last_message_at
      t.string :last_error
      t.integer :packets_total, null: false, default: 0
      t.datetime :started_at

      t.timestamps
    end
  end
end
