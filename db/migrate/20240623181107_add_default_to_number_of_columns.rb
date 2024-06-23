class AddDefaultToNumberOfColumns < ActiveRecord::Migration[7.1]
  def change
    change_column_default :boards, :number_of_columns, 6
  end
end
