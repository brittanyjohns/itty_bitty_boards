class AddGroupIdToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :board_group_id, :integer
    add_index :boards, :board_group_id
  end
end
