class AddBoardImagesCountToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :board_images_count, :integer, default: 0, null: false
  end
end
