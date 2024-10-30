class AddGroupLayoutToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :group_layout, :jsonb, default: []
  end
end
