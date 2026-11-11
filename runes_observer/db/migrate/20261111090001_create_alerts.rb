class CreateAlerts < ActiveRecord::Migration[8.1]
  # doc5.md O1.5. An Alert is a deduped, countable, ackable "abnormal" event:
  # detectors run in the ingest process and upsert by (kind, subject), so a
  # flapping agent is one row with a count, not a thousand rows.
  def change
    create_table :alerts do |t|
      t.string :kind, null: false
      t.string :severity, null: false, default: "warn"
      t.string :subject, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :count, null: false, default: 1
      t.boolean :acknowledged, null: false, default: false
      t.json :details
      t.timestamps
    end
    add_index :alerts, %i[kind subject], unique: true
    add_index :alerts, :acknowledged
  end
end
