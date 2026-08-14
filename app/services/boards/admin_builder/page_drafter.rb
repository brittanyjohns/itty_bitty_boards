module Boards
  module AdminBuilder
    # Drafts the word list for ONE child page, from that page's title.
    #
    # The output ONLY EVER POPULATES THE FORM, like every other drafter here. A
    # human edits it, previews the art, then builds.
    #
    # Deliberately not WordListDrafter with a different topic. That one opens
    # with CORE_SPINE and never emits a link, and both are wrong for a page: the
    # root carries the core words the whole set leans on, a page carries its own
    # subject's, and a page with no way home is a dead end for a communicator.
    # The prompt is SetDrafter's per-page half, scoped to a single page.
    #
    # Unlike SetDrafter there is no page ceiling here — one page per call is how
    # a set larger than SetDrafter::MAX_PAGES gets drafted without the per-page
    # tile counts slipping.
    #
    # No credit charge: the boards it drafts are admin-owned.
    class PageDrafter
      class GenerationError < StandardError; end

      # 12x12, matching the controller's grid ceiling.
      MAX_TILES = 144

      # Links are in the schema because a page owes the set exactly one: the way
      # home. `link_for` drops anything else the model puts there.
      SCHEMA = {
        name: "aac_page_word_list",
        strict: true,
        schema: {
          type: "object",
          additionalProperties: false,
          required: ["tiles"],
          properties: {
            tiles: { type: "array", items: Drafting.tile_schema },
          },
        },
      }.freeze

      # `topic` is the whole board's subject and is optional context — the page
      # title is the actual input, and a page can be drafted before the board
      # has a topic at all.
      def initialize(page_name:, tile_count:, page_key: nil, topic: nil, audience: nil)
        @page_name = page_name.to_s.strip
        @page_key = page_key.to_s.strip
        @tile_count = tile_count.to_i.clamp(1, MAX_TILES)
        @topic = topic.to_s.strip
        @audience = audience.to_s.strip
      end

      def call
        raise GenerationError, "give the page a name to draft from" if subject.blank?

        parse_response(generate_via_openai)
      end

      private

      attr_reader :page_name, :page_key, :tile_count, :topic, :audience

      # The key is a fallback rather than an equal: it's an identifier
      # ("my_turn"), so it only stands in when there is no title to read.
      def subject
        page_name.presence || page_key.tr("_", " ").strip
      end

      def generate_via_openai
        content = Drafting.chat(prompt: subject, content: build_prompt, schema: SCHEMA)
        raise GenerationError, "OpenAI returned no content" if content.blank?

        content
      end

      def build_prompt
        <<~PROMPT
          You are filling in ONE page of a set of AAC (Augmentative and Alternative
          Communication) boards for a nonspeaking communicator.

          The page is about: #{subject}
          #{topic.present? ? "It is a page on a board about: #{topic}" : ""}
          #{audience.present? ? "It is for: #{audience}" : ""}

          Generate EXACTLY #{tile_count} tiles for this page — it is a fixed grid and a
          count that doesn't fill whole rows leaves visible dead cells.

          Structure rules:
          - Exactly ONE tile goes back to the main board: label it "back", with
            "links_to" set to "#{Plan::ROOT_KEY}". It counts towards the #{tile_count} tiles.
          - No other tile has "links_to" — this page opens nothing further.

          Word rules:
          - This is a page, not the main board: the main board already carries the core
            words the whole set leans on, so spend these cells on #{subject} rather than
            repeating "I", "want", "more" and "help".
          - A page still has to be sayable on its own terms. Carry the verbs and the
            describing words that belong to #{subject} — what you DO there and what it
            is LIKE — not only the things you would find there.
          - Aim for roughly this balance: 30-40% verbs and core function words,
            15-20% pronouns and determiners, 15-20% describing words, 25-35% topic
            nouns. A page that is mostly nouns is a picture dictionary, not an AAC
            page.
          #{Drafting::WORD_RULES.rstrip}
          #{LabelCasing::PROMPT_RULE.rstrip}
          #{Drafting.part_of_speech_rules.rstrip}

          Respond in JSON format — every tile carries "proper_noun" and "links_to",
          with null where there is no link:
          {
            "tiles": [
              { "label": "hungry", "part_of_speech": "adjective", "proper_noun": false, "links_to": null },
              { "label": "apple", "part_of_speech": "noun", "proper_noun": false, "links_to": null },
              { "label": "back", "part_of_speech": "social", "proper_noun": false, "links_to": "#{Plan::ROOT_KEY}" }
            ]
          }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      # Arranged for the same reason as every other drafter: the order here is
      # the grid layout. The back tile carries `links_to`, so it sorts into the
      # bottom band — which keeps `BackTileAlignment`'s mirror-swap a move
      # between navigation cells rather than one that pulls a word out of its
      # colour block.
      def parse_response(raw)
        data = JSON.parse(raw)
        tiles = TileArrangement.arrange(dedupe(Array(data["tiles"])).first(tile_count))

        # Only a response with nothing usable in it is an error — this fills a
        # textarea, so a short draft is survivable and the form's counter shows
        # the gap.
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

          label = LabelCasing.sanitize(tile["label"] || tile["word"])
          next if label.blank?
          next unless seen.add?(label.downcase)

          part_of_speech = part_of_speech_for(tile)
          links_to = link_for(tile)

          {
            label: LabelCasing.apply(
              label,
              part_of_speech: part_of_speech,
              proper_noun: LabelCasing.proper_noun?(tile),
              door: links_to.present?,
            ),
            part_of_speech: part_of_speech,
            links_to: links_to,
          }.compact
        end
      end

      # An unrecognized value would be rejected by PlanValidator on preview, so
      # fall back to "default" (grey) and let the admin re-colour it rather than
      # handing back a list that can't be submitted.
      def part_of_speech_for(tile)
        value = tile["part_of_speech"].to_s.strip.downcase
        ColorHelper::PARTS_OF_SPEECH.include?(value) ? value : "default"
      end

      # Only the back edge survives. This drafter is given one page and knows no
      # other page's key, so a link anywhere else would name a page it can't
      # vouch for — and PlanValidator rejects a link to a key that isn't in the
      # set, which is worse than a tile that simply doesn't open anything.
      def link_for(tile)
        target = tile["links_to"].to_s.strip.downcase
        target == Plan::ROOT_KEY ? target : nil
      end
    end
  end
end
