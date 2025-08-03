class AddFeaturedToGroups < ActiveRecord::Migration[7.1]
  def up
    add_column :board_groups, :featured, :boolean, default: false, null: false if !column_exists?(:board_groups, :featured)
    add_index :board_groups, :featured unless index_exists?(:board_groups, :featured)
  end

  def down
    remove_index :board_groups, :featured if index_exists?(:board_groups, :featured)
    remove_column :board_groups, :featured if column_exists?(:board_groups, :featured)
  end
end
