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

      # `pages` are the pages the admin already named on the form, as
      # `{ key:, name: }` hashes. They are used verbatim and the model only
      # invents the rest — so a page count below the number of names would
      # throw away typed input, and the larger of the two wins.
      def initialize(topic:, columns:, tile_count:, page_count:, audience: nil, pages: [])
        @topic = topic.to_s.strip
        @tile_count = tile_count.to_i.clamp(1, MAX_TILES_PER_PAGE)
        @audience = audience.to_s.strip
        @columns = columns.to_i
        @pinned = clean_pinned(pages)
        @page_count = [page_count.to_i, @pinned.size].max.clamp(0, MAX_PAGES)
        @pinned = @pinned.first(@page_count)
      end

      def call
        raise GenerationError, "give the board a topic to draft from" if topic.blank?
        return single_page_set if page_count.zero?

        parse_response(generate_via_openai)
      end

      private

      attr_reader :topic, :tile_count, :page_count, :audience, :columns, :pinned

      # A page is pinned by whichever half the admin typed: a name alone gives
      # the key, a key alone gives the name. Blank blocks and duplicate keys are
      # dropped rather than sent to the prompt as noise.
      def clean_pinned(pages)
        seen = Set.new

        Array(pages).filter_map do |page|
          name = page[:name].to_s.strip
          key = Keys.normalize(page[:key].presence || name)
          next if key.blank?
          next unless seen.add?(key)

          { key: key, name: name.presence || key.titleize }
        end
      end

      # A set with no pages is exactly what WordListDrafter already answers.
      def single_page_set
        tiles = WordListDrafter.new(
          topic: topic, tile_count: tile_count, audience: audience.presence,
        ).call

        { root_tiles: tiles, children: [], page_count: page_count }
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

          #{pinned_pages_instruction}
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
          - A label is display text, not an identifier: separate words with a plain
            space, never an underscore. (Page "key" values are the one exception —
            those are underscored on purpose, per the structure rules above.)
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

      # The pinned pages are named in the prompt rather than merged in after the
      # fact because the root's folder tiles have to carry `links_to` for each
      # one — a key invented here and reconciled later would leave the root
      # linking to a page that no longer exists.
      def pinned_pages_instruction
        return "" if pinned.empty?

        listed = pinned.map { |page| %(- key "#{page[:key]}", name "#{page[:name]}") }.join("\n")
        remaining = page_count - pinned.size

        <<~TEXT
          These pages are already decided. Use these exact keys and names, in this order,
          and do not rename or merge them:
          #{listed}
          #{if remaining.positive?
              "Then add #{remaining} more #{"page".pluralize(remaining)} of your own that fit the " \
              "topic, with keys and names that don't repeat the ones above."
            else
              "Do not add any other pages."
            end}

        TEXT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        children = clean_children(Array(data["pages"]))
        child_keys = children.map { |child| child[:key] }
        root_tiles = clean_tiles(Array(data["root"]), known_keys: child_keys)

        # Only a response with nothing usable in it is an error — a short draft
        # fills the form and the counter shows the gap.
        raise GenerationError, "AI returned no usable words" if root_tiles.empty?

        # The count is echoed back because pinned pages can raise it above what
        # the form asked for, and the notice compares against what was actually
        # attempted.
        { root_tiles: root_tiles, children: children, page_count: page_count }
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
        end

        pages = apply_pinned(pages).first(page_count)

        keys = pages.map { |page| page[:key] }
        pages.map do |page|
          page.merge(tiles: clean_tiles(page[:tiles], known_keys: keys + [Plan::ROOT_KEY]))
        end
      end

      # The admin's key and name win even when the model paraphrased them: a
      # pinned page takes the response page with the same key, and otherwise the
      # next unclaimed one in order (the prompt asks for the pinned pages first).
      # A pinned page the model skipped entirely still appears, empty — the form
      # shows the gap and the page can be drafted on its own.
      def apply_pinned(pages)
        return pages if pinned.empty?

        remaining = pages.dup

        claimed = pinned.map do |page|
          match = remaining.find { |candidate| candidate[:key] == page[:key] } || remaining.first
          remaining.delete(match) if match

          { key: page[:key], name: page[:name], tiles: Array(match && match[:tiles]) }
        end

        claimed + remaining
      end

      def normalize_key(value)
        Keys.normalize(value)
      end

      def clean_tiles(raw_tiles, known_keys:)
        seen = Set.new

        raw_tiles.filter_map do |tile|
          next unless tile.is_a?(Hash)

          label = sanitize_label(tile["label"] || tile["word"])
          next if label.blank?
          next unless seen.add?(label.downcase)

          {
            label: label,
            part_of_speech: part_of_speech_for(tile),
            links_to: link_for(tile, known_keys),
          }.compact
        end.first(tile_count)
      end

      # The model occasionally answers a multi-word label snake_cased, like an
      # identifier rather than the tile text it's meant to be — underscores
      # have no legitimate place in display text, so they're folded to spaces
      # rather than left for the admin to notice and retype. Distinct from
      # normalize_key: a page "key" is meant to be underscored.
      def sanitize_label(raw)
        raw.to_s.strip.tr("_", " ").squeeze(" ").strip
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
