# So a run's packets can be listed next to its steps.
class AddRunIdToPackets < ActiveRecord::Migration[8.1]
  def change
    add_column :packets, :run_id, :string
    add_index :packets, :run_id
  end
end
