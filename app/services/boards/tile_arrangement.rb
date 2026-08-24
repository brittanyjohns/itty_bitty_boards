module Boards
  # Puts a drafted tile list in the order it should be READ ON THE GRID.
  #
  # **The drafted order IS the layout.** Both callers turn a position straight
  # into a cell — `Build#apply_reading_order!` for the admin Board Builder and
  # `Board#format_board_with_ai` for the user-facing "Format with AI" button —
  # so whatever order they are handed is exactly what someone sees laid out and
  # what a communicator scans. Left to the model's own ordering, the Modified
  # Fitzgerald colours the builder already applies per tile come out as
  # confetti: a verb, a noun, a pronoun, a noun. Same words, much harder board.
  #
  # So: a stable sort into part-of-speech bands. Like words land contiguous,
  # each colour reads as a block, and the quick words a communicator needs
  # first (pronouns, yes/no/more, stop) are in the opening cells rather than
  # wherever the model happened to put them.
  #
  # **This is a PERMUTATION and nothing else.** No tile is added, dropped,
  # relabelled or relinked, so nothing downstream can be affected by it:
  # counts still satisfy PlanValidator, `FolderTiles` still finds every link,
  # and `BackTileAlignment` still mirrors the same set of tiles. Keep it that
  # way — the moment this can change a count it becomes something preview has
  # to re-check.
  #
  # Column-free on purpose. Bands can't be made to break on row boundaries
  # without padding the grid, and the grid must be exactly full.
  module TileArrangement
    # Top to bottom. Quick words first — pronouns, then the social words and
    # the protest words, then question words — because those are what a
    # communicator reaches for under pressure and the top-left cells are the
    # cheapest to reach. Then the sentence: verb, how, what kind, where, which,
    # and the topic nouns last.
    #
    # Interpolated into every drafter's prompt (`PROMPT_RULE`), so the order
    # the model is asked for and the order Ruby enforces cannot drift.
    BAND_ORDER = %w[
      pronoun
      social
      important_function
      question
      verb
      adverb
      adjective
      preposition
      determiner
      conjunction
      noun
      default
    ].freeze

    # Doors and back tiles sort after every word band. The app's boards put
    # navigation on the bottom row (see `.claude-notes/board-builder.md`), and
    # a back tile in the bottom band keeps `BackTileAlignment`'s mirror-swap a
    # bottom-to-bottom move instead of dragging a word out of its colour block.
    LINK_BAND = BAND_ORDER.size

    PROMPT_RULE = <<~RULE.freeze
      - Group the tiles by part of speech and list the groups in exactly this
        order, with any tile that has a "links_to" last of all:
        #{BAND_ORDER.join(", ")}
        Tiles are laid out left to right in the order you list them, so a
        grouped list is what puts like words next to each other on the grid.
    RULE

    module_function

    # `tiles` are Plan tile hashes (`{ label:, part_of_speech:, links_to: }`).
    # Idempotent: sorting an already-arranged list returns it unchanged.
    def arrange(tiles)
      Array(tiles)
        .map { |tile| correct_part_of_speech(tile) }
        .each_with_index
        .sort_by { |tile, index| [band_for(tile), index] }
        .map(&:first)
    end

    def band_for(tile)
      return LINK_BAND if tile[:links_to].present?

      BAND_ORDER.index(tile[:part_of_speech].to_s) || BAND_ORDER.index("default")
    end

    # A wrong part of speech is a wrong colour AND now a wrong band, so it is
    # worth correcting before sorting rather than leaving for an admin to
    # spot. `AacWordCategorizer::OVERRIDES` is already keyed by communicative
    # function — the exact thing the prompts ask for, and the exact thing
    # models get wrong ("stop" as a verb, "more" as an adjective).
    #
    # The OVERRIDES table only, never `AacWordCategorizer.categorize`: that
    # falls through to one paid OpenAI call PER WORD, which would turn a
    # 144-tile draft into 144 requests to fix colours a schema-constrained
    # response mostly got right.
    def correct_part_of_speech(tile)
      tile = tile.dup
      # A door's label is a page name, not a word — "Play" opens a page and
      # must not be recoloured because a word table happens to know "play".
      return tile if tile[:links_to].present?

      key = AacWordCategorizer.normalize(tile[:label])
      override = AacWordCategorizer::OVERRIDES[key]
      tile[:part_of_speech] = override if override.present?
      tile
    end
  end
end

