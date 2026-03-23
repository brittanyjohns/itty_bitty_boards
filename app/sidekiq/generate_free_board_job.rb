class GenerateFreeBoardJob
  include Sidekiq::Job

  def perform(board_id, topic, age_range, word_count)
    board = Board.find_by(id: board_id)
    if board
      begin
        text = "I have an AAC board for the topic '#{topic}'. "
        text += "The age range for the person using the board is #{age_range}. Please provide a list of #{word_count} words that are appropriate for this age range and context. "
        Rails.logger.info "Generating words for board: #{board.id} with prompt: #{text}"
        board.update_column(:status, "generating_words")
        words = board.get_word_suggestions_from_prompt(text)
        Rails.logger.info "Generated words for board #{board.id}: #{words.inspect}"

        # create_board_tiles_from_words(board, words)
        board.update_column(:status, "finding_images")
        board.find_or_create_images_from_word_list(words)
        board.update_column(:status, "processing")
        board.reset_layouts
        GenerateBoardPreviewJob.perform_async(board.id, "lg", false, true, false)

        # GenerateBoardPreviewJob.perform_in(2.minute, board.id, "lg", false, true, true)

        board.update_column(:status, "complete")
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - GenerateFreeBoardJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
