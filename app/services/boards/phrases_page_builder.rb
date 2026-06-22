# app/services/boards/phrases_page_builder.rb
#
# Builds the gestalt "Phrases" layer for a Board Builder set: a "Phrases" board
# whose tiles are folder links to per-function gestalt pages (Greetings,
# Requests, Protests, Comments, Feelings, Transitions), each cloned from the
# seeded Boards::GlpTemplates function boards. Whole-phrase tiles keep
# part_of_speech: "phrase" (clone_with_images dups the BoardImage, and the
# admin phrase Image carries the POS), so no art is generated for them.
#
# This service only constructs the Phrases sub-tree. The caller
# (BuildBoardSetJob) links it from the home board and wires it as the
# communicator's phrase_board_id.
module Boards
  class PhrasesPageBuilder
    PHRASES_BOARD_NAME = "Phrases".freeze

    def initialize(communicator:, owner:)
      @communicator = communicator
      @owner = owner
    end

    # Creates the Phrases board + its function sub-pages and returns the Phrases
    # board (not yet linked to any home board). Returns nil when no GLP function
    # boards are seeded (so the caller skips the layer cleanly).
    def call
      sources = Boards::GlpTemplates.function_boards
      return nil if sources.empty?

      phrases_board = build_board(PHRASES_BOARD_NAME)

      sources.each do |source|
        cloned = clone_function_page(source)
        next unless cloned

        add_folder_tile(phrases_board, source.name, cloned.id)
      end

      phrases_board
    end

    private

    def build_board(name)
      board = Board.new(name: name, user: @owner)
      board.board_type = "static"
      board.assign_parent
      board.voice = VoiceService.normalize_voice(@communicator.voice)
      board.generate_unique_slug
      board.settings = (board.settings || {}).merge("builder_child" => true)
      board.save!
      board
    end

    # Clone a seeded GLP function board onto the owner. clone_with_images
    # preserves tile order, part_of_speech ("phrase"), and resolves the admin
    # phrase Images — phrase tiles render as colored script tiles, no art needed.
    def clone_function_page(source)
      cloned = source.clone_with_images(@owner.id)
      return nil unless cloned

      cloned.settings = (cloned.settings || {}).merge("builder_child" => true)
      cloned.save!
      cloned
    end

    # Mirrors BuildBoardSetJob#add_folder_tile! but scoped to the freshly-built,
    # empty Phrases board (no grid-cap concerns here). Pins the tile label to the
    # function name so a resolved art image can't rename it.
    def add_folder_tile(board, name, predictive_board_id)
      image = Boards::ImageResolver.resolve(name, owner: @owner)
      tile = board.add_image(image.id)
      tile&.update!(predictive_board_id: predictive_board_id, label: name, display_label: name)
      tile
    end
  end
end
