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

      def initialize(topic:, columns:, rows:, audience: nil)
        @topic = topic.to_s.strip
        @tile_count = (columns.to_i * rows.to_i).clamp(1, MAX_TILES)
        @audience = audience.to_s.strip
      end

      def call
        raise GenerationError, "give the board a topic to draft from" if topic.blank?

        parse_response(generate_via_openai)
      end

      private

      attr_reader :topic, :tile_count, :audience

      def generate_via_openai
        client = OpenAiClient.new(
          prompt: topic,
          messages: [{ role: "user", content: build_prompt }],
        )
        client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
        result = client.create_chat(true)

        raise GenerationError, "OpenAI returned no content" if result[:content].blank?

        result[:content]
      end

      # A small grid can't carry the whole spine, so ask for as much of it as
      # fits rather than for words that were never going to be there.
      def spine_for_size
        CORE_SPINE.first([tile_count, CORE_SPINE.size].min)
      end

      def build_prompt
        <<~PROMPT
          You are building an AAC (Augmentative and Alternative Communication) board for a
          nonspeaking communicator. The board's topic is: #{topic}
          #{audience.present? ? "It is for: #{audience}" : ""}

          Generate EXACTLY #{tile_count} tiles — the board is a fixed grid and a partial
          last row leaves visible dead cells.

          Start with these core words, in this order, before any topic words:
          #{spine_for_size.join(", ")}

          Then fill the rest with topic words, aiming for roughly this balance across the
          whole list:
          - 30-40% verbs and core function words (the words that do the communicating)
          - 15-20% pronouns and determiners
          - 15-20% describing words
          - 25-35% topic nouns

          Rules:
          - A board for talking, not a vocabulary list. Favour words that finish a
            sentence over words that name a thing.
          - No near-duplicates ("happy" and "glad", "big" and "large"). Each tile costs a
            cell.
          - Keep each label short — 1-2 words.
          - Concrete and age-appropriate.
          - Give every tile a part_of_speech from exactly this list:
            #{ColorHelper::PARTS_OF_SPEECH.join(", ")}
          - Classify by communicative function, not strict grammar: "more", "yes" and
            "please" are social; "no", "not" and "stop" are important_function.

          Respond in JSON format:
          {
            "tiles": [
              { "label": "I", "part_of_speech": "pronoun" },
              { "label": "want", "part_of_speech": "verb" }
            ]
          }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        tiles = dedupe(Array(data["tiles"])).first(tile_count)

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
      def dedupe(raw_tiles)
        seen = Set.new

        raw_tiles.filter_map do |tile|
          next unless tile.is_a?(Hash)

          label = (tile["label"] || tile["word"]).to_s.strip
          next if label.blank?
          next unless seen.add?(label.downcase)

          { label: label, part_of_speech: part_of_speech_for(tile) }
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
