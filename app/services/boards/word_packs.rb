# app/services/boards/word_packs.rb
#
# Curated, static sets of words a user can drop onto a board in one action from
# the Add-tiles modal ("Quick add"). Pronouns, action words, greetings, numbers
# — plus menu-only sets (sizes, condiments, ordering phrases) surfaced on
# restaurant-menu boards.
#
# THE POINT OF THIS FILE IS THAT IT COSTS NOTHING. Adding a word normally fires
# OpenAI twice, and neither call is credit-gated:
#
#   1. Image#ensure_defaults calls AacWordCategorizer.categorize for any new
#      image with no authored part_of_speech — a SYNCHRONOUS chat call, inside
#      the request, once per novel word. Its OVERRIDES table covers 37 words,
#      so "he", "medium" and "ketchup" all miss and hit the API.
#   2. Board#find_or_create_images_from_word_list queues GenerateImagesJob
#      (DALL-E) for every word with no art in the library.
#
# A pack declares its own part_of_speech, so (1) never happens: ensure_defaults
# takes the explicit-POS branch. The caller passes max_generate: 0, so (2)
# never happens either. As a bonus the tiles come out with the *authored*
# Fitzgerald colour rather than an LLM guess.
#
# Sibling to Boards::InterestCategories, deliberately NOT an extension of it:
# that constant is a reverse index routing an interest into a folder page, and
# its words must live in exactly one list for the index to be unambiguous.
#
# Consumed by API::WordPacksController (catalog) and
# API::BoardsController#add_word_pack (the add). The frontend mirror is
# itty-bitty-frontend/src/data/word_packs.ts.
module Boards
  module WordPacks
    # "phrase" is a real, deliberate part_of_speech (whole-utterance gestalt
    # tiles — see Image#ensure_defaults) but it is not in the Fitzgerald
    # vocabulary ColorHelper switches on, so it has to be named separately here.
    VALID_PARTS_OF_SPEECH = (ColorHelper::PARTS_OF_SPEECH + ["phrase"]).freeze

    PACKS = [
      {
        key: "pronouns",
        name: "Pronouns",
        description: "The people words — who is doing what.",
        part_of_speech: "pronoun",
        words: %w[I you he she it we they me my mine your him her us them],
      },
      {
        key: "actions",
        name: "Action words",
        description: "Verbs that carry most of a day.",
        part_of_speech: "verb",
        words: %w[
          go want need like help play eat drink look come get make put open
          close give turn read write wash sit stand walk run jump stop
        ],
      },
      {
        key: "social",
        name: "Greetings & social",
        description: "Hello, please, thank you — the words that start and end a turn.",
        part_of_speech: "social",
        words: [
          "hi", "hello", "bye", "goodbye", "please", "thank you",
          "you're welcome", "excuse me", "sorry", "yes", "no", "okay",
          "my turn", "your turn", "more", "again", "all done",
        ],
      },
      {
        key: "numbers",
        name: "Numbers",
        description: "Zero through ten.",
        part_of_speech: "determiner",
        words: %w[zero one two three four five six seven eight nine ten],
      },
      {
        key: "sizes",
        name: "Sizes",
        description: "How much or how big.",
        part_of_speech: "adjective",
        board_types: %w[menu],
        words: ["small", "medium", "large", "extra large", "kids size",
                "half", "whole", "a little", "a lot"],
      },
      {
        key: "condiments",
        name: "Extras & condiments",
        description: "The things you ask for on the side.",
        part_of_speech: "noun",
        board_types: %w[menu],
        words: ["ketchup", "mustard", "mayo", "ranch", "barbecue sauce",
                "hot sauce", "soy sauce", "salt", "pepper", "butter", "syrup",
                "sugar", "cream", "lemon", "ice", "napkin", "straw"],
      },
      {
        key: "ordering",
        name: "Ordering",
        description: "Whole phrases for ordering and asking at the table.",
        part_of_speech: "phrase",
        board_types: %w[menu],
        words: ["I want", "I would like", "Can I have", "No thank you",
                "That's all", "More please", "Check please", "To go",
                "For here", "Water please", "I'm all done", "I'm allergic"],
      },
    ].freeze

    # NOTE for the menu packs: on a menu board the authored part_of_speech is
    # deliberately IGNORED. A menu board is not an AAC board — its tiles are
    # white and look up no part of speech — so a word with no library match
    # takes Board#find_or_create_images_from_word_list's `is_a_menu?` branch and
    # becomes a private `image_type: "menu"` image instead. That path skips the
    # categorizer too (ensure_defaults short-circuits menu images to "noun"),
    # so the packs stay free either way; only the colour differs. The declared
    # part_of_speech still matters for the same pack added to a normal board.

    module_function

    # Every pack, unfiltered.
    def all
      PACKS
    end

    # The packs offered for `board`. A pack with no `board_types` is always
    # offered; one that names them is offered only on a matching board. Menu
    # boards are identified by Board#is_a_menu? (board_type OR a Menu parent) —
    # `board_type` alone misses menus created before it was set.
    def for_board(board)
      types = board_types_for(board)
      PACKS.select { |pack| pack[:board_types].blank? || (pack[:board_types] & types).any? }
    end

    def find(key)
      PACKS.find { |pack| pack[:key] == key.to_s }
    end

    def words_for(key)
      find(key)&.fetch(:words, []) || []
    end

    # The words of `key` that the caller actually asked for, in the pack's own
    # order. Anything not in the pack is dropped — the client names a key, the
    # server owns the vocabulary, so a caller can neither invent labels nor
    # smuggle a part_of_speech past the categorizer.
    def requested_words(key, requested)
      pack_words = words_for(key)
      return [] if pack_words.empty?

      wanted = Array(requested).map { |word| normalize_key(word) }.to_set
      pack_words.select { |word| wanted.include?(normalize_key(word)) }
    end

    # `normalized word => part_of_speech` for `words`, in the shape
    # Board#find_or_create_images_from_word_list expects (mirroring its existing
    # `menu_prompts:` kwarg).
    #
    # AacWordCategorizer::OVERRIDES wins over the pack's own default. That table
    # encodes deliberate AAC-functional choices a grammatical label would get
    # wrong — "stop" and "no" are protests (important_function), not a verb and
    # not a social word — and an authored part_of_speech silently beats the
    # categorizer. Deferring to it makes a contradiction impossible to author.
    def part_of_speech_map(key, words)
      pack = find(key)
      return {} unless pack

      Array(words).each_with_object({}) do |word, map|
        normalized = normalize_key(word)
        next if normalized.blank?

        map[normalized] = AacWordCategorizer::OVERRIDES[normalized] || pack[:part_of_speech]
      end
    end

    # The normalized labels ALREADY on `board`, read straight from its tiles.
    #
    # Deliberately not `Board#current_word_list`: that serves a cached
    # `data["current_word_list"]` whenever one is present, and nothing
    # invalidates it when a tile is destroyed — so a word the user deleted still
    # reads as placed. Here that would grey the word out in the picker AND make
    # the add skip it, leaving no way to get it back. One query, always true.
    def placed_keys(board)
      return Set.new if board.nil?

      board.board_images.pluck(:label, :display_label)
           .flatten.compact
           .map { |label| normalize_key(label) }
           .reject(&:blank?)
           .to_set
    end

    # The lookup key for a word: the same normalization the tile-creation path
    # applies, then downcased, since label matching is case-insensitive.
    def normalize_key(word)
      Boards::InterestWords.normalize_word(word).to_s.downcase
    end

    def board_types_for(board)
      return [] if board.nil?

      types = [board.board_type.to_s]
      types << "menu" if board.is_a_menu?
      types.compact_blank.uniq
    end
  end
end
