module Boards
  module AdminBuilder
    # Drafts a word list for a board of a given size and topic: one OpenAI call
    # returning `[{ label:, part_of_speech: }]`.
    #
    # The output ONLY EVER POPULATES THE FORM. It is never fed to a build
    # directly — a human edits it, then previews the art, then builds. That is
    # the whole reason this returns plain data and touches nothing.
    #
    # Deliberately a new prompt rather than a composition of the pieces that
    # already exist: `Board#get_words_for_scenario` needs a persisted Board and
    # returns bare strings with no part of speech, and
    # `AacWordCategorizer.categorize` is one OpenAI call PER WORD — chaining
    # them is an N+1 against a paid API for something one call answers.
    #
    # No credit charge: the boards this drafts are admin-owned.
    class WordListDrafter
      class GenerationError < StandardError; end

      # The words that make a board usable for something other than labelling.
      # Placed first so they land in the top-left, where they are reachable.
      CORE_SPINE = [
        "I", "you", "it", "want", "go", "stop", "more", "help",
        "like", "not", "yes", "all done", "look", "my turn", "what", "where"
      ].freeze

      # 12x12, matching the controller's grid ceiling.
      MAX_TILES = 144

      # No `links_to`: this drafter replaces a whole word list and knows nothing
      # about the pages in the set, so a link it invented would name a page that
      # doesn't exist. `FolderTiles` writes the doors back in afterwards.
      SCHEMA = {
        name: "aac_word_list",
        strict: true,
        schema: {
          type: "object",
          additionalProperties: false,
          required: ["tiles"],
          properties: {
            tiles: { type: "array", items: Drafting.tile_schema(links: false) },
          },
        },
      }.freeze

      # existing_labels switches the prompt from "draft a whole board" to "add
      # N more tiles to one that already has these" — used when topping up a
      # list an admin already started rather than replacing it.
      def initialize(topic:, tile_count:, audience: nil, existing_labels: [])
        @topic = topic.to_s.strip
        @tile_count = tile_count.to_i.clamp(1, MAX_TILES)
        @audience = audience.to_s.strip
        @existing_labels = Array(existing_labels).map(&:to_s)
      end

      def call
        raise GenerationError, "give the board a topic to draft from" if topic.blank?

        parse_response(generate_via_openai)
      end

      private

      attr_reader :topic, :tile_count, :audience, :existing_labels

      def generate_via_openai
        content = Drafting.chat(prompt: topic, content: build_prompt, schema: SCHEMA)
        raise GenerationError, "OpenAI returned no content" if content.blank?

        content
      end

      # A small grid can't carry the whole spine, so ask for as much of it as
      # fits rather than for words that were never going to be there.
      def spine_for_size
        CORE_SPINE.first([tile_count, CORE_SPINE.size].min)
      end

      def build_prompt
        return topup_prompt if existing_labels.any?

        <<~PROMPT
          You are building an AAC (Augmentative and Alternative Communication) board for a
          nonspeaking communicator. The board's topic is: #{topic}
          #{audience.present? ? "It is for: #{audience}" : ""}

          Generate EXACTLY #{tile_count} tiles — the board is a fixed grid and a partial
          last row leaves visible dead cells.

          The board must include these core words — they are what makes it usable for
          something other than labelling:
          #{spine_for_size.join(", ")}

          Fill the rest with topic words, aiming for roughly this balance across the
          whole list:
          - 30-40% verbs and core function words (the words that do the communicating)
          - 15-20% pronouns and determiners
          - 15-20% describing words
          - 25-35% topic nouns
          A board that is mostly nouns is a picture dictionary, not an AAC board.

          Rules:
          #{Drafting::WORD_RULES.rstrip}
          #{LabelCasing::PROMPT_RULE.rstrip}
          #{Drafting.part_of_speech_rules.rstrip}

          Respond in JSON format:
          {
            "tiles": [
              { "label": "i", "part_of_speech": "pronoun", "proper_noun": false },
              { "label": "want", "part_of_speech": "verb", "proper_noun": false },
              { "label": "all done", "part_of_speech": "social", "proper_noun": false }
            ]
          }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      # Tops up a list the admin already started rather than drafting a whole
      # board — no core spine recitation, since it may already be on the list
      # (or the admin left it off on purpose).
      def topup_prompt
        <<~PROMPT
          You are extending an existing AAC (Augmentative and Alternative Communication)
          board for a nonspeaking communicator. The board's topic is: #{topic}
          #{audience.present? ? "It is for: #{audience}" : ""}

          The board already has these tiles — do not repeat any of them:
          #{existing_labels.join(", ")}

          Generate EXACTLY #{tile_count} NEW tiles that round out the existing list with
          topic words the board doesn't have yet.

          Rules:
          - Read the existing list before choosing: fill what it is MISSING. If it has
            no way to refuse or redirect, that is the first gap to close; if it is all
            nouns, add the verbs and describing words that make them sayable.
          - No near-duplicates of each other or of the existing words ("happy" next to
            "glad", "big" next to "large").
          #{Drafting::WORD_RULES.rstrip}
          #{LabelCasing::PROMPT_RULE.rstrip}
          #{Drafting.part_of_speech_rules.rstrip}

          Respond in JSON format:
          {
            "tiles": [
              { "label": "swing", "part_of_speech": "noun", "proper_noun": false },
              { "label": "push", "part_of_speech": "verb", "proper_noun": false }
            ]
          }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      # Arranged, not just deduped: the drafted order IS the grid layout
      # downstream (`Build#apply_reading_order!`), so grouping the list by part
      # of speech here is what puts like words next to each other on the board.
      # `TileArrangement.arrange` is a permutation, so the count the caller sees
      # is unaffected.
      #
      # In top-up mode this arranges only the NEW tiles — the caller appends them
      # to a list the admin may have typed by hand, and re-sorting someone's
      # authored order because they asked for a few more words is not the deal.
      def parse_response(raw)
        data = JSON.parse(raw)
        tiles = TileArrangement.arrange(dedupe(Array(data["tiles"])).first(tile_count))

        # Unlike Boards::AiPageGenerator — which builds from its response — this
        # only fills a textarea, so a short draft is survivable: the form's
        # counter shows the gap and the admin types the rest. Only a response
        # with nothing usable in it is an error.
        raise GenerationError, "AI returned no usable words" if tiles.empty?

        tiles
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # Exact and casing-only repeats are dropped here rather than left for
      # PlanValidator: `images.label` is a lowercase matching key, so "Go" and
      # "go" are one symbol, and a draft that fails validation on arrival is
      # worse than a short one. Near-duplicates are the prompt's job.
      #
      # Seeded with existing_labels too, so a top-up drops anything the AI
      # repeats from the list it was told to avoid, on top of repeats within
      # its own response.
      def dedupe(raw_tiles)
        seen = Set.new(existing_labels.map(&:downcase))

        raw_tiles.filter_map do |tile|
          next unless tile.is_a?(Hash)

          label = LabelCasing.sanitize(tile["label"] || tile["word"])
          next if label.blank?
          next unless seen.add?(label.downcase)

          part_of_speech = part_of_speech_for(tile)
          {
            label: LabelCasing.apply(
              label,
              part_of_speech: part_of_speech,
              proper_noun: LabelCasing.proper_noun?(tile),
            ),
            part_of_speech: part_of_speech,
          }
        end
      end

      # An unrecognized value would be rejected by PlanValidator on preview, so
      # fall back to "default" (grey) and let the admin re-colour it rather than
      # handing back a list that can't be submitted.
      def part_of_speech_for(tile)
        value = tile["part_of_speech"].to_s.strip.downcase
        ColorHelper::PARTS_OF_SPEECH.include?(value) ? value : "default"
      end
    end
  end
end
