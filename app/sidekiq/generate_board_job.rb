class GenerateBoardJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(board_id, board_creation_type, options = {})
    word_count = options["word_count"].presence || options["wordCount"].presence.to_i || 12
    board = Board.find_by(id: board_id)
    # info, not debug: production runs at :info, so this pipeline was
    # invisible in the journal when we had to trace a bad board.
    Rails.logger.info "GenerateBoardJob start board=#{board_id} creation_type=#{board_creation_type} topic_present=#{options["topic"].to_s.strip.present?} word_count=#{word_count} seed_count=#{(options["word_list"] || options["wordList"] || []).compact.size}"
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
          # The APPROVED word list is authoritative. The user reviews these
          # chips and taps "Create board"; anything added afterwards lands on
          # the board having never been shown to anyone.
          #
          # This used to generate a SECOND list from the topic and merge it in,
          # so a 24-word approval produced a 26-tile board. The two extras were
          # `happy` and `sad` — near-duplicates of the approved `I feel happy`
          # and `I feel sad`, which the second generation was never told about:
          # its exclusion clause reads `data["current_word_list"]`, and that is
          # empty until tiles exist. Nor can this detect "the user typed no
          # situation" and generate only then, because boards#create forces
          # `topic` to the board NAME for a scenario board. The presence of
          # seed words is the signal, and it is the right one: they are what
          # was confirmed.
          #
          # Enrichment is not forbidden — it has to happen before the approval
          # step, where it can be seen and edited. Prompts::Aac.with_core_floor
          # runs there for exactly that reason.
          seed_words = (options["word_list"] || options["wordList"] || []).compact
          topic = options["topic"].to_s.strip
          age_range = options["age_range"].presence || options["ageRange"].presence

          generated = []
          if seed_words.empty? && topic.present?
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
          # Case-insensitive: Image.by_label matches on LOWER(label), so
          # "Dog" and "dog" resolve to one Image but a plain .uniq would
          # still create two tiles showing the same picture.
          words = (seed_words + generated).uniq { |w| w.to_s.strip.downcase }
          Rails.logger.info "GenerateBoardJob words board=#{board.id} seed=#{seed_words.size} generated=#{generated.size} final=#{words.size}"
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
