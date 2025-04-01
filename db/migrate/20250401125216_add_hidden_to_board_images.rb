class AddHiddenToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :hidden, :boolean, default: false
    add_index :board_images, :hidden
  end
end
