class ImportFromObfJob
  include Sidekiq::Job

  def perform(board_data, user_id, board_group_id = nil, board_id = nil)
    current_user = User.find_by(id: user_id)
    return unless current_user
    puts "Importing from OBF file"
    board_group = BoardGroup.find_by(id: board_group_id, user_id: current_user.id) if board_group_id
    if board_id.blank?
      puts "No board ID provided for import"
      board_name = board_data["name"] || "Imported Board"
      @board = Board.new(name: board_name, user: current_user)
      @board.assign_parent
    else
      @board = Board.find_by(id: board_id, user_id: current_user.id)
      unless @board
        puts "Board with ID #{board_id} not found for user #{current_user.id}"
        return
      end
      puts "Found board with ID #{board_id} for import"
    end
    @board, _data = Board.from_obf(board_data, current_user, board_group, @board.id)
    if @board
      @board.update(status: "active")
      puts "Board import completed successfully for board ID #{@board.id}"
    else
      puts "Board import failed"
    end
  rescue => e
    Rails.logger.error "Error during board import: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    if @board
      @board.reset_layouts
      @board.update(status: "error")
      Rails.logger.error "Board status set to error for board ID #{@board.id}"
    end
  end
end
