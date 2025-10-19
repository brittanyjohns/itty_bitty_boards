class ImportFromObfJob
  include Sidekiq::Job

  def perform(board_data, user_id, board_group_id = nil)
    current_user = User.find_by(id: user_id)
    return unless current_user
    unless board_data.is_a?(Hash)
      Rails.logger.error "Invalid board data provided for import: #{board_data.class.name}"
      return
    end
    Rails.logger.debug "Importing from OBF file"
    board_group = BoardGroup.find_by(id: board_group_id, user_id: current_user.id) if board_group_id
    board_name = board_data["name"] || "Imported Board"
    @board = Board.new(name: board_name, user: current_user, status: "importing")
    @board.assign_parent
    unless @board.save
      Rails.logger.debug "Failed to create board: #{@board.errors.full_messages.join(", ")}"
      return
    end
    Rails.logger.debug "Created new board with ID #{@board.id} for import"
    @board, _data = Board.from_obf(board_data, current_user, board_group, @board.id)
    if @board
      @board.update(status: "active")
      Rails.logger.debug "Board import completed successfully for board ID #{@board.id}"
    else
      Rails.logger.debug "Board import failed"
      @board.update(status: "error")
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
