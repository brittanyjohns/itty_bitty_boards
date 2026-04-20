class AddBorderToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :border_width, :integer, default: 0, null: false
    add_column :board_images, :border_radius, :integer, default: 0, null: false
  end
end
