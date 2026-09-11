class GenerateFreeBoardJob
  include Sidekiq::Job

  def perform(board_id, topic, age_range, word_count)
    board = Board.find_by(id: board_id)
    if board
      begin
        board.update_column(:status, "generating_words")
        # This is a WHOLE board being laid out from nothing, so it goes through
        # the same method the logged-in path uses. It used to hand-roll a prompt
        # and call #get_word_suggestions_from_prompt directly, which ran under
        # the incremental "add words" system prompt (no BOARD_COVERAGE_RULES
        # since #879) and never reached Prompts::Aac.with_core_floor — so an
        # anonymous "snack time" board came back as twelve foods with no
        # yes/no/more/help/stop. #get_words_for_scenario applies the core floor
        # and the same CommunicatorProfile age handling. (#911)
        words = Array(board.get_words_for_scenario(topic, age_range, word_count))

        if words.empty?
          # with_core_floor tops a list up; it does not manufacture one. An AI
          # response with nothing in it is a failure, and marking the board
          # complete here would ship a six-tile core-only board as if it were
          # the board the user asked for. Leave the status where it is.
          Rails.logger.warn "GenerateFreeBoardJob: no words generated for Board ID #{board.id}"
          return
        end

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
