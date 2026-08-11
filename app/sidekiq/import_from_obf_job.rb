class ImportFromObfJob
  include Sidekiq::Job

  # `board_id` is the placeholder row API::BoardsController#import_obf creates
  # inside the request, so the client gets an id to poll. The create-it-here
  # branch is kept for jobs enqueued by an older deploy.
  #
  # Status vocabulary is the one BoardGenerationStatusPage polls and every
  # other generation job writes: processing -> complete / failed.
  def perform(board_data, user_id, board_group_id = nil, import_options = {}, board_id = nil)
    current_user = User.find_by(id: user_id)
    return unless current_user
    unless board_data.is_a?(Hash)
      Rails.logger.error "[ImportFromObfJob] invalid board data for import: #{board_data.class.name}"
      return
    end

    board_group = BoardGroup.find_by(id: board_group_id, user_id: current_user.id) if board_group_id
    @board = resolve_board(board_id, board_data, current_user)
    return unless @board

    @board.update_column(:status, "processing")
    imported, _data = Board.from_obf(board_data, current_user, board_group, @board.id, import_options: import_options || {})
    if imported
      @board = imported
      @board.update_column(:status, "complete")
    else
      Rails.logger.error "[ImportFromObfJob] import produced no board (board_id=#{@board.id})"
      @board.update_column(:status, "failed")
    end
  rescue => e
    Rails.logger.error "[ImportFromObfJob] error during board import: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    if @board
      @board.reset_layouts
      @board.update_column(:status, "failed")
      Rails.logger.error "[ImportFromObfJob] board #{@board.id} marked failed"
    end
  end

  private

  def resolve_board(board_id, board_data, current_user)
    if board_id
      board = current_user.boards.find_by(id: board_id)
      Rails.logger.error "[ImportFromObfJob] board #{board_id} not found for user #{current_user.id}" unless board
      return board
    end

    board = Board.new(
      name: board_data["name"].presence || "Imported Board",
      user: current_user,
      status: "processing",
    )
    board.assign_parent
    # Not optional: `boards.slug` defaults to "" and `validates :slug,
    # uniqueness: true` does not skip blanks, so a board saved without a
    # generated slug collides with the first slug-less row in the table.
    board.generate_unique_slug
    return board if board.save

    Rails.logger.error "[ImportFromObfJob] failed to create board: #{board.errors.full_messages.join(", ")}"
    nil
  end
end
