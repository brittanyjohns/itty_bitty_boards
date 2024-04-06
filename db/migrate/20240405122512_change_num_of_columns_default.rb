class ChangeNumOfColumnsDefault < ActiveRecord::Migration[7.1]
  def change
    remove_column :boards, :number_of_columns
    add_column :boards, :number_of_columns, :integer, default: 2
  end
end
