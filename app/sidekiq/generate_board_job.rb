class GenerateBoardJob
  include Sidekiq::Job

  def perform(board_id, board_creation_type, options = {})
    word_count = options["word_count"].presence || options["wordCount"].presence.to_i || 12
    board = Board.find_by(id: board_id)
    if board
      words = []
      begin
        board.update_column(:status, "generating_words")

        case board_creation_type
        when "default"
          words = options["word_list"] || options["wordList"] || []
        when "scenario"
          topic = options["topic"].to_s.strip
          age_range = options["age_range"].presence || options["ageRange"].presence
          words = get_words_for_scenario(topic, age_range, word_count)
        when "menu"
          # Placeholder for future menu-based word generation logic
          words = []
        else
          words = []
        end

        # create_board_tiles_from_words(board, words)
        board.update_column(:status, "finding_images")
        board.find_or_create_images_from_word_list(words)
        board.update_column(:status, "processing")
        board.reset_layouts
        GenerateBoardPreviewJob.perform_async(board.id, "lg", false, true, false)

        GenerateBoardPreviewJob.perform_in(2.minute, board.id, "lg", false, true, true)

        board.update_column(:status, "complete")
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - GenerateBoardJob #{board.id} #{board_creation_type} \n\nERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}\n"
      end
    end
  end

  def get_words_for_scenario(topic, age_range, word_count)
    text = "I have an AAC board for the topic '#{topic}'. "
    text += "The age range for the person using the board is #{age_range}. Please provide a list of #{word_count} words that are appropriate for this age range and context. "
    Rails.logger.info "Generating words for board: #{board.id} with prompt: #{text}"
    words = board.get_word_suggestions_from_prompt(text)
    Rails.logger.info "Generated words for board #{board.id}: #{words.inspect}"
    words
  end
end
