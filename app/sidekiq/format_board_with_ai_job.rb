class FormatBoardWithAiJob
  include Sidekiq::Job

  def perform(board_id, screen_size = "lg")
    board = Board.find(board_id)
    unless board
      puts "Board not found: #{board_id}"
      return
    end
    result = board.format_board_with_ai(screen_size)
    unless result
      puts "Board format with AI failed: #{board_id}"
      return
    end
    board.update(status: "formatted")
    puts "Board format with AI success: #{board_id}"
    # Do something
  end
end