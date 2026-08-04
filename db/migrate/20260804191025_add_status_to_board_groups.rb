class AddStatusToBoardGroups < ActiveRecord::Migration[8.0]
  def change
    add_column :board_groups, :status, :string
  end
end
