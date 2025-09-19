class AddOriginalBoardIdToChildBoards < ActiveRecord::Migration[7.1]
  def up
    add_reference :child_boards, :original_board, foreign_key: { to_table: :boards }, index: true
    add_column :boards, :in_use, :boolean, default: false, null: false
    add_column :boards, :is_template, :boolean, default: false, null: false

    # Backfill existing child_boards with original_board_id
    puts "Backfilling ChildBoards with original_board_id and creating template Boards..."
    ChildBoard.reset_column_information
    Board.reset_column_information
    Board.non_menus.includes(:user, { child_boards: :child_account }).find_each do |og_board|
      user = og_board.user
      puts "Processing Original Board ID #{og_board.id} (#{og_board.name}) by User ID #{user&.id}"
      og_board.child_boards.each do |child_board|
        child_account = child_board.child_account
        user = child_account.user
        next unless user
        cloned_board = og_board.clone_with_images(user&.id, "#{og_board.name}")
        puts "Backfilling ChildBoard ID #{child_board.id} with OriginalBoard ID #{og_board.id} by creating Template Board ID #{cloned_board.id}"
        cloned_board.is_template = true
        cloned_board.save!
        child_board.update(original_board: og_board, board: cloned_board)
      end
    rescue => e
      Rails.logger.error "Failed to backfill ChildBoard ID #{child_board.id}: #{e.message}"
      next
    end
  end

  def down
    puts "Removing original_board_id from ChildBoards and deleting template Boards..."
    child_boards = ChildBoard.includes(:original_board, :board).where.not(original_board_id: nil)
    child_boards.each do |child_board|
      if child_board.original_board
        og_board = child_board.original_board
        puts "Removing original_board_id from ChildBoard ID #{child_board.id}"
        child_board.update(original_board: nil, board: child_board.original_board)
        og_board.destroy if og_board.is_template
      end
    end
    template_boards = Board.non_menus.where(is_template: true)
    remove_reference :child_boards, :original_board, foreign_key: { to_table: :boards }, index: true
    remove_column :boards, :in_use, :boolean, default: false, null: false
    remove_column :boards, :is_template, :boolean, default: false, null: false
  end
end
