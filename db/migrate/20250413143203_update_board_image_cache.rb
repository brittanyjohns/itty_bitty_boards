class UpdateBoardImageCache < ActiveRecord::Migration[7.1]
  def change
    Board.includes(:board_images).all.each do |board|
      Board.reset_counters(board.id, :board_images)
    end
  end
end
