class FormatBoardWithAiJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 2, backtrace: true

  def perform(board_id, screen_size = "lg", maintain_existing_layout = false)
    board = Board.find(board_id)
    unless board
      Rails.logger.error "Board not found: #{board_id}"
      return
    end
    result = board.format_board_with_ai(screen_size: screen_size, maintain_existing_layout: maintain_existing_layout)
    unless result
      Rails.logger.error "Board format with AI failed: #{board_id}"
      return
    end
    board.update(status: "formatted")
  end
end
