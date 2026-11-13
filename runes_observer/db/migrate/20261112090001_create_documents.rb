class CreateDocuments < ActiveRecord::Migration[8.1]
  # docs/WORKSPACE_PLAN.md slice 2A: uploaded documents, addressed by the
  # SHA-256 of their content (the harness's Runes::DocStore layout), so a
  # packet payload can reference one by hash and two identical uploads are
  # one file on disk.
  def change
    create_table :documents do |t|
      t.string :sha, null: false
      t.string :ext, null: false
      t.integer :bytes, null: false
      t.string :name, null: false
      t.string :uploaded_by
      t.integer :first_packet_id
      t.timestamps
    end
    add_index :documents, %i[sha ext], unique: true
    add_index :documents, :created_at
  end
end
