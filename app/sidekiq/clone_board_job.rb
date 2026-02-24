class CloneBoardJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  def perform(board_id, new_board_image_id, level_count = 0)
    board = Board.find_by(id: board_id)
    new_board_image = BoardImage.find_by(id: new_board_image_id)
    cloned_user_id = new_board_image.board.user_id
    voice_value = board.voice
    return unless board
    # make sure the user doesn't already have a predictive board with the same words
    user_boards = Board.where(user_id: cloned_user_id)
    board_words = board.current_word_list
    matching_boards = user_boards.where("name ILIKE ?", board.name)
    if matching_boards.any?
      # check words
      matching_boards.each do |matching_board|
        matched_word_list = matching_board.current_word_list
        if matched_word_list.sort == board_words.sort
          Rails.logger.info "User #{cloned_user_id} already has a board with the same name and words, skipping cloning predictive board for board image: #{new_board_image.id}"
          return
        else
          Rails.logger.info "User #{cloned_user_id} has a board with the same name but different words, proceeding with cloning predictive board for board image: #{new_board_image.id}"
        end
      end
    end
    new_predictive_board = board.clone_with_images(cloned_user_id, board.name, voice_value, nil, level_count)
    Rails.logger.info "Cloned predictive board: #{board.id} to new predictive board: #{new_predictive_board.id} for board image: #{new_board_image.id}"
    if new_predictive_board
      new_board_image.predictive_board_id = new_predictive_board.id
      new_board_image.save
    else
      Rails.logger.error "Error cloning predictive board: #{new_predictive_board.id} for board image: #{new_board_image.id}"
    end

    # (cloned_user_id, predictive_board.name, updated_voice, nil, level_count)
  end
end
