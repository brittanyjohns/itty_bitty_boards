class RmGroupIdFromBoards < ActiveRecord::Migration[7.1]
  def up
    remove_column :boards, :board_group_id, :integer, null: true if column_exists?(:boards, :board_group_id)
    remove_index :boards, :board_group_id if index_exists?(:boards, :board_group_id)
  end

  def down
    remove_index :board_group_boards, [:board_group_id, :position] if index_exists?(:board_group_boards, [:board_group_id, :position])
    remove_column :board_group_boards, :group_layout if column_exists?(:board_group_boards, :group_layout)
    remove_column :board_group_boards, :position if column_exists?(:board_group_boards, :position)
  end
end
