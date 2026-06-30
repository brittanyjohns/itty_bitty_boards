class UpdateUserBoardsJob
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 2

  def perform(cloned_board_id, source_board_id)
    # Best-effort post-clone fixup. Either board can be deleted between
    # enqueue and run (e.g. the user discards a just-cloned board), so a
    # missing record is a no-op, not a failure worth retrying/alerting on.
    cloned_board = Board.find_by(id: cloned_board_id)
    source_board = Board.find_by(id: source_board_id)
    return unless cloned_board && source_board

    cloned_board.update_user_boards_after_cloning(source_board, cloned_board.user_id)
  end
end
