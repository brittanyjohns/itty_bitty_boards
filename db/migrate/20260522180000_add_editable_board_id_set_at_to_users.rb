class AddEditableBoardIdSetAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :editable_board_id_set_at, :datetime
  end
end
