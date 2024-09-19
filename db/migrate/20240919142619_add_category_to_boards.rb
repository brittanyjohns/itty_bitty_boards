class AddCategoryToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :category, :string
    add_index :boards, :category
    add_column :images, :category, :string
    add_index :images, :category
  end
end
