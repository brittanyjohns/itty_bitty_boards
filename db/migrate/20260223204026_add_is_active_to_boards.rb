class AddIsActiveToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :sub_board, :boolean, default: true, null: false
    Board.reset_column_information
    Board.find_each do |board|
      board.save!
    end
  end
end
