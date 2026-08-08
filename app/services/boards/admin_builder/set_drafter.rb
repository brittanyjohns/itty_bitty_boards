module Boards
  module AdminBuilder
    # Drafts a whole linked board set in one OpenAI call: the root word list
    # with its folder tiles already carrying link targets, plus each child
    # page's key, name and word list.
    #
    # The output ONLY EVER POPULATES THE FORM, like WordListDrafter. A human
    # edits it, previews the art, then builds.
    #
    # Two rules of PlanValidator decide the prompt's shape and must be honoured
    # here rather than discovered at preview:
    #   * every page must exactly fill its grid, so the per-page tile count is
    #     stated explicitly;
    #   * every page shares the root's grid, so a child is never given a grid
    #     of its own.
    #
    # No credit charge: the boards it drafts are admin-owned.
    class SetDrafter
      class GenerationError < StandardError; end

      # More pages than this in one call and the response gets long enough that
      # the per-page tile counts start slipping.
      MAX_PAGES = 4
      # 12x12, matching the controller's grid ceiling.
      MAX_TILES_PER_PAGE = 144

      def initialize(topic:, columns:, tile_count:, page_count:, audience: nil)
        @topic = topic.to_s.strip
        @tile_count = tile_count.to_i.clamp(1, MAX_TILES_PER_PAGE)
        @page_count = page_count.to_i.clamp(0, MAX_PAGES)
        @audience = audience.to_s.strip
        @columns = columns.to_i
      end

      def call
        raise GenerationError, "give the board a topic to draft from" if topic.blank?
        return single_page_set if page_count.zero?

        parse_response(generate_via_openai)
      end

      private

      attr_reader :topic, :tile_count, :page_count, :audience, :columns

      # A set with no pages is exactly what WordListDrafter already answers.
      def single_page_set
        tiles = WordListDrafter.new(
          topic: topic, tile_count: tile_count, audience: audience.presence,
        ).call

        { root_tiles: tiles, children: [] }
      rescue WordListDrafter::GenerationError => e
        raise GenerationError, e.message
      end

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

      def build_prompt
        <<~PROMPT
          You are building a set of AAC (Augmentative and Alternative Communication) boards
          for a nonspeaking communicator. The set's topic is: #{topic}
          #{audience.present? ? "It is for: #{audience}" : ""}

          The set is a main board plus exactly #{page_count} pages. Each page is opened by a
          folder tile on the main board.

          Generate EXACTLY #{tile_count} tiles for the main board AND EXACTLY #{tile_count}
          tiles for each page — every board in the set is #{columns} columns wide with the
          same tile count, and a count that doesn't fill whole rows leaves visible dead cells.

          Structure rules:
          - Give every page a "key": lowercase letters, numbers and underscores only.
          - Every page must have exactly one tile on the main board that opens it. Give that
            tile "links_to" set to the page's key. It counts towards the main board's
            #{tile_count} tiles.
          - Every page must include one tile that goes back, with "links_to" set to
            "#{Plan::ROOT_KEY}". It counts towards that page's #{tile_count} tiles.
          - No other tile has "links_to".

          Word rules:
          - Boards for talking, not vocabulary lists. Favour words that finish a sentence
            over words that name a thing.
          - The main board carries the core words the whole set leans on — pronouns, verbs,
            and words like "more", "stop", "help". Pages carry their own subject's words.
          - No near-duplicates within a board ("happy" and "glad"). Each tile costs a cell.
          - Keep each label short — 1-2 words.
          - Give every tile a part_of_speech from exactly this list:
            #{ColorHelper::PARTS_OF_SPEECH.join(", ")}
          - Classify by communicative function, not strict grammar: "more", "yes" and
            "please" are social; "no", "not" and "stop" are important_function.

          Respond in JSON format:
          {
            "root": [
              { "label": "I", "part_of_speech": "pronoun" },
              { "label": "Food", "part_of_speech": "noun", "links_to": "food" }
            ],
            "pages": [
              {
                "key": "food",
                "name": "Food",
                "tiles": [
                  { "label": "apple", "part_of_speech": "noun" },
                  { "label": "back", "part_of_speech": "social", "links_to": "#{Plan::ROOT_KEY}" }
                ]
              }
            ]
          }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        children = clean_children(Array(data["pages"]))
        child_keys = children.map { |child| child[:key] }
        root_tiles = clean_tiles(Array(data["root"]), known_keys: child_keys)

        # Only a response with nothing usable in it is an error — a short draft
        # fills the form and the counter shows the gap.
        raise GenerationError, "AI returned no usable words" if root_tiles.empty?

        { root_tiles: root_tiles, children: children }
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # Keys are cleaned before any tile is, because a tile's link is only kept
      # when it names a page that survived.
      def clean_children(raw_pages)
        seen = Set.new

        pages = raw_pages.filter_map do |page|
          next unless page.is_a?(Hash)

          key = normalize_key(page["key"])
          next if key.blank?
          next unless seen.add?(key)

          { key: key, name: page["name"].to_s.strip.presence || key.titleize, tiles: Array(page["tiles"]) }
        end.first(page_count)

        keys = pages.map { |page| page[:key] }
        pages.map do |page|
          page.merge(tiles: clean_tiles(page[:tiles], known_keys: keys + [Plan::ROOT_KEY]))
        end
      end

      # Strips leading/trailing underscores from a slugified key — except when
      # the value already equals the root sentinel, which is nothing but
      # underscores and would otherwise be stripped to blank.
      def normalize_key(value)
        cleaned = value.to_s.strip.downcase.gsub(/[^a-z0-9_]+/, "_")
        return cleaned if cleaned == Plan::ROOT_KEY

        cleaned.gsub(/\A_+|_+\z/, "")
      end

      def clean_tiles(raw_tiles, known_keys:)
        seen = Set.new

        raw_tiles.filter_map do |tile|
          next unless tile.is_a?(Hash)

          label = (tile["label"] || tile["word"]).to_s.strip
          next if label.blank?
          next unless seen.add?(label.downcase)

          {
            label: label,
            part_of_speech: part_of_speech_for(tile),
            links_to: link_for(tile, known_keys),
          }.compact
        end.first(tile_count)
      end

      def part_of_speech_for(tile)
        value = tile["part_of_speech"].to_s.strip.downcase
        ColorHelper::PARTS_OF_SPEECH.include?(value) ? value : "default"
      end

      # A link naming a page that isn't in the set would fail PlanValidator on
      # arrival, which is worse than a tile that simply doesn't open anything.
      def link_for(tile, known_keys)
        target = normalize_key(tile["links_to"])
        return nil if target.blank? || known_keys.exclude?(target)

        target
      end
    end
  end
end
