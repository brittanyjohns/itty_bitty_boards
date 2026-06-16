class GenerateBoardJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(board_id, board_creation_type, options = {})
    word_count = options["word_count"].presence || options["wordCount"].presence.to_i || 12
    board = Board.find_by(id: board_id)
    Rails.logger.debug "Starting GenerateBoardJob for Board ID #{board_id} with creation type #{board_creation_type} and options: #{options.inspect}"
    if board
      words = []
      begin
        board.update_column(:status, "generating_words")
        # communicator_id arrives pre-validated (boards#create scopes it to
        # the caller's own communicator_accounts before enqueueing). Explicit
        # profile params still override the stored fields, field by field.
        communicator = ChildAccount.find_by(id: options["communicator_id"]) if options["communicator_id"].present?
        profile = CommunicatorProfile.for(params: options["profile"] || {}, communicator: communicator)
        case board_creation_type
        when "default", "scenario"
          # The merged "Build a board" form can send seed words (word_list)
          # and a topic together. Seed words are used as-is; when a topic is
          # present we also generate scenario words and combine them. A board
          # with seed words but no topic just keeps the seed words.
          seed_words = (options["word_list"] || options["wordList"] || []).compact
          topic = options["topic"].to_s.strip
          age_range = options["age_range"].presence || options["ageRange"].presence

          generated = []
          if topic.present?
            if word_count <= 0 || word_count > 80
              Rails.logger.warn "Word count of #{word_count} is out of bounds for Board ID #{board.id}."
              # `|| 6` doesn't fire on 0 (truthy in Ruby), which mattered when
              # api/internal/boards#create coerced missing columns to 0. Guard
              # against any caller that still produces a zero column count.
              lrg_cols = board.large_screen_columns.to_i.positive? ? board.large_screen_columns : 6
              word_count = lrg_cols * 4
            end
            generated = board.get_words_for_scenario(topic, age_range, word_count, profile: profile) || []
          end
          words = (seed_words + generated).uniq
        when "menu"
          # Placeholder for future menu-based word generation logic
          words = []
        when "predictive"
          starting_phrase_or_word = options["starting_phrase_or_word"] || options["startingPhraseOrWord"]
          words = options["word_list"] || options["wordList"] || []
          words = board.get_words_for_predictive(starting_phrase_or_word, word_count, profile: profile) if words.empty?
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

        sleep(2) # add a short sleep to ensure the preview job starts before we mark the board as complete
        board.update_column(:status, "complete")
      rescue => e
        Rails.logger.error "\n**** SIDEKIQ - GenerateBoardJob #{board.id} #{board_creation_type} \n\nERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}\n"
      end
    else
      Rails.logger.error "GenerateBoardJob: Board with ID #{board_id} not found."
    end
  end
end
