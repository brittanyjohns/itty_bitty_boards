class AddEditableBoardIdToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :editable_board_id, :bigint
    add_index :users, :editable_board_id
  end
end
