class GenerateBoardJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(board_id, board_creation_type, options = {})
    word_count = options["word_count"].presence || options["wordCount"].presence.to_i || 12
    board = Board.find_by(id: board_id)
    Rails.logger.info "Starting GenerateBoardJob for Board ID #{board_id} with creation type #{board_creation_type} and options: #{options.inspect}"
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
          words = board.get_words_for_scenario(topic, age_range, word_count)
        when "menu"
          # Placeholder for future menu-based word generation logic
          words = []
        when "predictive"
          starting_phrase_or_word = options["starting_phrase_or_word"] || options["startingPhraseOrWord"]
          words = options["word_list"] || options["wordList"] || []
          words = board.get_words_for_predictive(starting_phrase_or_word, word_count) if words.empty?
        else
          words = options["word_list"] || options["wordList"] || []
        end
        if words.empty?
          Rails.logger.warn "No words generated for Board ID #{board.id} with creation type #{board_creation_type}"
          board.update_column(:status, "complete")
          return
        end

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
end
