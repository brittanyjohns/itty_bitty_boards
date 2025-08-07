class AddDescriptionToGroups < ActiveRecord::Migration[7.1]
  def change
    add_column :board_groups, :description, :text
    add_index :board_groups, :description
  end
end
