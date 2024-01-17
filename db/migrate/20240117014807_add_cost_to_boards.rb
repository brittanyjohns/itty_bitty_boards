class AddCostToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :cost, :integer, default: 0
    add_column :boards, :predefined, :boolean, default: false
  end
end
