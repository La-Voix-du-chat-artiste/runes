# Workflows used to run in-process and publish nothing, so the observatory
# could not see them at all (doc5.md O1.1). A run's telemetry events are now
# projected into these two tables, which is what the Runs views read.
class CreateWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_runs do |t|
      t.string :run_id, null: false
      t.string :workflow, null: false
      t.string :status, null: false, default: "running"
      t.datetime :started_at
      t.datetime :finished_at
      t.float :duration_ms
      t.integer :step_count, null: false, default: 0
      t.text :error
      t.text :params
      t.string :agent_id

      t.timestamps
    end
    add_index :workflow_runs, :run_id, unique: true
    add_index :workflow_runs, :started_at
    add_index :workflow_runs, :status
    add_index :workflow_runs, :workflow

    create_table :workflow_steps do |t|
      t.references :workflow_run, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string :rune
      t.string :name
      t.string :scope
      t.string :status, null: false, default: "running"
      t.boolean :async, null: false, default: false
      t.float :duration_ms
      t.datetime :started_at
      t.datetime :finished_at
      t.text :input
      t.text :output
      t.text :error

      t.timestamps
    end
    add_index :workflow_steps, %i[workflow_run_id position]
  end
end
