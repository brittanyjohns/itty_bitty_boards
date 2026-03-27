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
          if word_count <= 0 || word_count > 80
            Rails.logger.warn "Word count of #{word_count} is out of bounds for Board ID #{board.id}."
            lrg_cols = board.large_screen_columns || 6
            word_count = lrg_cols * 4
          end
          words = get_words_for_scenario(board, topic, age_range, word_count)
        when "menu"
          # Placeholder for future menu-based word generation logic
          words = []
        when "predictive"
          starting_phrase_or_word = options["starting_phrase_or_word"] || options["startingPhraseOrWord"] || ""
          words = board.get_words_for_predictive(starting_phrase_or_word, word_count)
        else
          words = options["word_list"] || options["wordList"] || []
        end
        if words.empty?
          Rails.logger.warn "No words generated for Board ID #{board.id} with creation type #{board_creation_type}"
          board.update_column(:status, "complete")
          return
        end

        # create_board_tiles_from_words(board, words)
        board.update_column(:status, "finding_images")
        board.find_or_create_images_from_word_list(words)
        board.update_column(:status, "processing")
        board.reset_layouts

        board.generate_previews # generate new preview image with generated words

        board.update_column(:status, "complete")
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - GenerateBoardJob #{board.id} #{board_creation_type} \n\nERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}\n"
      end
    else
      Rails.logger.error "GenerateBoardJob: Board with ID #{board_id} not found."
    end
  end

  def get_words_for_scenario(board, topic, age_range, word_count)
    board_name = board.name.presence || "the board"
    words_to_exclude = board.data["current_word_list"] || []
    # ensure word count is reasonable to avoid excessively long prompts & not 0
    if word_count <= 0 || word_count > 80
      Rails.logger.warn "Word count of #{word_count} is out of bounds for Board ID #{board.id}. Defaulting to 12."
      word_count = 24
    end
    text = "Generate a list of words for a communication board. The topic or theme of the board is #{topic}. The name of the board is #{board_name}. "
    text += "The age range for the person using the board is #{age_range}. Please provide a list of #{word_count} words that are appropriate for this age range and context. "
    text += "Exclude words that are too similar to each other or that would not be useful on a communication board. Also exclude words that are already on the board: #{words_to_exclude.join(", ")}." if words_to_exclude.any?
    words = board.get_word_suggestions_from_prompt(text)
    words
  end
end
