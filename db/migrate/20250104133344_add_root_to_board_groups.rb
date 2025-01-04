class AddRootToBoardGroups < ActiveRecord::Migration[7.1]
  def change
    add_column :board_groups, :root_board_id, :integer
    add_foreign_key :board_groups, :boards, column: :root_board_id
    add_index :board_groups, :root_board_id
    add_column :board_groups, :original_obf_root_id, :string
    add_index :board_groups, :original_obf_root_id
  end
end
