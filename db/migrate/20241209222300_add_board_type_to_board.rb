class AddBoardTypeToBoard < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :board_type, :string
    add_index :boards, :board_type
    Board.where(board_type: nil).each do |board|
      tmp_board_type = board.tmp_board_type
      puts "Updating board #{board.name} with board_type: #{tmp_board_type} -  parent_type: #{board.parent_type}\n"
      board.update(board_type: tmp_board_type)
    end
  end
end
