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

      # A board this close to its target is left alone: PlanValidator tolerates
      # a much wider gap than this, so a follow-up call would be paying for
      # cosmetics.
      TOPUP_THRESHOLD = 5
      # Ceiling on follow-up calls for one draft, root and pages together. A set
      # whose every board comes back short is a prompt problem, not something to
      # spend six sequential API calls papering over while the admin waits.
      MAX_TOPUPS = 3

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
        @topups = 0
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
        content = Drafting.chat(prompt: topic, content: build_prompt)
        raise GenerationError, "OpenAI returned no content" if content.blank?

        content
      end

      # A small grid can't carry the whole spine, so ask for as much of it as
      # fits rather than for words that were never going to be there. The folder
      # tiles are subtracted first — they are not optional, so a grid with fewer
      # cells than pages has no room for core words at all.
      def spine_for_size
        spine = WordListDrafter::CORE_SPINE
        spine.first((tile_count - page_count).clamp(0, spine.size))
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

          What a page should BE:
          - A page is a place the communicator goes, an activity they do, or a routine they
            move through — not a category of things. For a board about the park: good pages
            are "Playground", "Snack Time", "Going Home"; bad pages are "Equipment",
            "Animals", "Colors", which are lists to read rather than places to talk from.
          - Name a page for the moment it serves, so a communicator can guess what is behind
            the tile before they open it.

          Main board rules:
          - Start the main board with these core words, in this order, before any topic
            words — they are what makes the whole set usable for something other than
            labelling, and they belong on the board every page returns to:
            #{spine_for_size.join(", ")}
          - Then the folder tiles, then whatever main-board topic words still fit.

          Word rules:
          - Boards for talking, not vocabulary lists. Favour words that finish a sentence
            over words that name a thing.
          - Aim for roughly this balance across each board:
            30-40% verbs and core function words (the words that do the communicating),
            15-20% pronouns and determiners, 15-20% describing words, 25-35% topic nouns.
            A board that is mostly nouns is a picture dictionary, not an AAC board.
          - A page must NOT repeat a word that is already on the main board. The
            communicator reaches those from the main board, so a repeat spends a cell and
            buys nothing.
          - No near-duplicates within a board ("happy" and "glad"). Each tile costs a cell.
          - Keep each label short — 1-2 words.
          - A label is display text, not an identifier: separate words with a plain
            space, never an underscore. (Page "key" values are the one exception —
            those are underscored on purpose, per the structure rules above.)
          #{LabelCasing::PROMPT_RULE.rstrip}
          - Give every tile a part_of_speech from exactly this list:
            #{ColorHelper::PARTS_OF_SPEECH.join(", ")}
          - Classify by communicative function, not strict grammar: "more", "yes" and
            "please" are social; "no", "not" and "stop" are important_function.

          Respond in JSON format:
          {
            "root": [
              { "label": "i", "part_of_speech": "pronoun" },
              { "label": "want", "part_of_speech": "verb" },
              { "label": "Snack Time", "part_of_speech": "noun", "links_to": "snack_time" }
            ],
            "pages": [
              {
                "key": "snack_time",
                "name": "Snack Time",
                "tiles": [
                  { "label": "hungry", "part_of_speech": "adjective" },
                  { "label": "open it", "part_of_speech": "verb" },
                  { "label": "Goldfish", "part_of_speech": "noun", "proper_noun": true },
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
        # Keys are settled before any tile is cleaned, because a tile's link is
        # only kept when it names a page that survived.
        shells = page_shells(Array(data["pages"]))
        keys = shells.map { |page| page[:key] }

        root_tiles = clean_tiles(Array(data["root"]), known_keys: keys)

        # Only a response with nothing usable in it is an error — a short draft
        # fills the form and the counter shows the gap.
        raise GenerationError, "AI returned no usable words" if root_tiles.empty?

        root_tiles = top_up(root_tiles, subject: topic)
        # What a page may not repeat. Resolved from the root AFTER its top-up so
        # a word the top-up added is covered too.
        taken = root_tiles.map { |tile| tile[:label] }

        children = shells.map do |page|
          tiles = clean_tiles(page[:tiles], known_keys: keys + [Plan::ROOT_KEY], taken: taken)
          page.merge(tiles: top_up(tiles, subject: page[:name], taken: taken))
        end

        # The count is echoed back because pinned pages can raise it above what
        # the form asked for, and the notice compares against what was actually
        # attempted.
        { root_tiles: root_tiles, children: children, page_count: page_count }
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # The pages, keyed and named but with their tiles still raw.
      def page_shells(raw_pages)
        seen = Set.new

        pages = raw_pages.filter_map do |page|
          next unless page.is_a?(Hash)

          key = normalize_key(page["key"])
          next if key.blank?
          next unless seen.add?(key)

          { key: key, name: page["name"].to_s.strip.presence || key.titleize, tiles: Array(page["tiles"]) }
        end

        apply_pinned(pages).first(page_count)
      end

      # A board that came back well short used to just sit in the form with a
      # warning on it, leaving the admin to type the rest by hand — which is the
      # job they pressed the button to avoid. One follow-up call fills the gap,
      # reusing WordListDrafter's existing top-up prompt (`existing_labels:` is
      # what switches it into that mode) so the filler words know what not to
      # repeat.
      #
      # Bounded twice over: nothing under TOPUP_THRESHOLD is worth a paid call
      # (the grid tolerates it and the notice says so), and MAX_TOPUPS caps the
      # whole draft so a set of consistently short pages can't turn one click
      # into six sequential API calls. A failed top-up is not an error — the
      # short list is still a usable draft.
      def top_up(tiles, subject:, taken: [])
        short = tile_count - tiles.size
        return tiles if short <= TOPUP_THRESHOLD || subject.blank? || @topups >= MAX_TOPUPS

        @topups += 1
        extra = WordListDrafter.new(
          topic: subject,
          tile_count: short,
          audience: audience.presence,
          existing_labels: (taken + tiles.map { |tile| tile[:label] }).uniq,
        ).call

        (tiles + extra).first(tile_count)
      rescue WordListDrafter::GenerationError => e
        Rails.logger.warn("[SetDrafter] top-up failed for #{subject.inspect}: #{e.message}")
        tiles
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

      # `taken` seeds the dedupe set with labels a page must not repeat — the
      # root's words, when cleaning a page. Dedupe was per-board, so a core word
      # the root already carries came back on every page and spent a cell buying
      # nothing: the communicator can already reach it from the main board.
      def clean_tiles(raw_tiles, known_keys:, taken: [])
        seen = Set.new(taken.map(&:downcase))

        raw_tiles.filter_map do |tile|
          next unless tile.is_a?(Hash)

          label = LabelCasing.sanitize(tile["label"] || tile["word"])
          next if label.blank?
          next unless seen.add?(label.downcase)

          part_of_speech = part_of_speech_for(tile)
          links_to = link_for(tile, known_keys)

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
