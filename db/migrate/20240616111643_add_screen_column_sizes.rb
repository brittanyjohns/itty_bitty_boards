class AddScreenColumnSizes < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :small_screen_columns, :integer, default: 3
    add_column :boards, :medium_screen_columns, :integer, default: 8
    add_column :boards, :large_screen_columns, :integer, default: 12
  end
end
