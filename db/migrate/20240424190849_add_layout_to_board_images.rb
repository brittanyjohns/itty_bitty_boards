class AddLayoutToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :layout, :jsonb, default: {}
    BoardImage.all.each do |board_image|
      board_image.update(layout: {i: board_image.id, x: board_image.grid_x, y: board_image.grid_y, w: 1, h: 1})
    end
  end
end
