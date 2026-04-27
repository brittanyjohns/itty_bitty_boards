class FormatBoardWithAiJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 2, backtrace: true

  def perform(options)
    board_id = options["board_id"]
    screen_size = options["screen_size"] || "lg"
    maintain_existing_layout = options["maintain_existing_layout"].nil? ? false : options["maintain_existing_layout"]
    board = Board.find(board_id)
    unless board
      Rails.logger.error "Board not found: #{board_id}"
      return
    end
    begin
      result = board.format_board_with_ai(screen_size: screen_size, maintain_existing_layout: maintain_existing_layout)
      unless result
        Rails.logger.error "Board format with AI failed: #{board_id}"
        return
      end
    rescue => e
      Rails.logger.error "Error in FormatBoardWithAiJob for Board ID #{board_id}: #{e.message}\n#{e.backtrace.join("\n")}"
      return
    ensure
      board.update_column(:status, "complete")
    end
  end
end
