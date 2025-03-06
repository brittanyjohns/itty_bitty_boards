class UpdateUserBoardsJob
  include Sidekiq::Job

  def perform(cloned_board_id, source_board_id)
    cloned_board = Board.find(cloned_board_id)
    source_board = Board.find(source_board_id)

    cloned_board.update_user_boards_after_cloning(source_board)
  end
end
