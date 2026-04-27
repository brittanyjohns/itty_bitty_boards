class GenerateFreeBoardJob
  include Sidekiq::Job

  def perform(board_id, topic, age_range, word_count)
    board = Board.find_by(id: board_id)
    if board
      begin
        text = "I have an AAC board for the topic '#{topic}'. "
        text += "The age range for the person using the board is #{age_range}. Please provide a list of #{word_count} words that are appropriate for this age range and context. "
        Rails.logger.debug "Generating words for board: #{board.id} with prompt: #{text}"
        board.update_column(:status, "generating_words")
        words = board.get_word_suggestions_from_prompt(text)

        # downcase word unless it's a proper character (e.g. "I") or contains uppercase letters (e.g. "NASA") or is a phrase (e.g. "What's up?")
        words = words.map do |word|
          if word.length > 1 || word.match(/[A-Z]/) || word.include?(" ")
            word
          else
            if word.downcase == "i"
              "I"
            else
              word.downcase
            end
          end
        end
        Rails.logger.debug "Generated words for board #{board.id}: #{words.inspect}"

        # create_board_tiles_from_words(board, words)
        board.update_column(:status, "finding_images")
        board.find_or_create_images_from_word_list(words)
        board.update_column(:status, "processing")
        board.reset_layouts
        board.generate_previews # generate new preview image with generated words
        sleep(2) # add a short sleep to ensure the preview job starts before we mark the board as complete
        board.update_column(:status, "complete")
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - GenerateFreeBoardJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
