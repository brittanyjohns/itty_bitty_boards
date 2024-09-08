class AddModeToBoardImage < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :mode, :integer, default: "static", if_not_exists: true
    add_column :board_images, :dynamic_board_id, :integer, if_not_exists: true
    add_index :board_images, :dynamic_board_id, if_not_exists: true
  end
end
