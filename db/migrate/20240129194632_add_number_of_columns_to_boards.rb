class AddNumberOfColumnsToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :number_of_columns, :integer
  end
end
