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
          Rails.logger.info "Generating board with scenario. Topic: #{topic}, Age Range: #{age_range}, Word Count: #{word_count}"
          words = get_words_for_scenario(board, topic, age_range, word_count)
        when "menu"
          # Placeholder for future menu-based word generation logic
          words = []
        else
          Rails.logger.warn "Unknown board creation type: #{board_creation_type} for Board ID #{board.id}. Defaulting to default word list."
          words = options["word_list"] || options["wordList"] || []
        end
        Rails.logger.info "Words generated for Board ID #{board.id}: #{words.inspect}"
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

        board.run_generate_preview_job

        board.update_column(:status, "complete")
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - GenerateBoardJob #{board.id} #{board_creation_type} \n\nERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}\n"
      end
    end
  end

  def get_words_for_scenario(board, topic, age_range, word_count)
    board_name = board.name.presence || "the board"
    words_to_exclude = board.data["current_word_list"] || []
    text = "Generate a list of words for a communication board. The topic or theme of the board is #{topic}. The name of the board is #{board_name}. "
    text += "The age range for the person using the board is #{age_range}. Please provide a list of #{word_count} words that are appropriate for this age range and context. "
    text += "Exclude words that are too similar to each other or that would not be useful on a communication board. Also exclude words that are already on the board: #{words_to_exclude.join(", ")}." if words_to_exclude.any?
    Rails.logger.info "Generating words for board: #{board.id} with prompt: #{text}"
    words = board.get_word_suggestions_from_prompt(text)
    Rails.logger.info "Generated words for board #{board.id}: #{words.inspect}"
    words
  end
end
