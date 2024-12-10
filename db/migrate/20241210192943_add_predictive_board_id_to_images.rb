class AddPredictiveBoardIdToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :predictive_board_id, :integer
    add_index :images, :predictive_board_id
    Image.where(predictive_board_id: nil).each do |image|
      category_boards = image.category_boards
      category_board = category_boards.first
      puts "Category board: #{category_board.name}" if category_board
      image.update!(predictive_board_id: category_board.id) if category_board
      predictive_boards = image.predictive_boards
      predictive_board_id = predictive_boards.first&.id
      image.update!(predictive_board_id: predictive_board_id)
    end
  end
end
