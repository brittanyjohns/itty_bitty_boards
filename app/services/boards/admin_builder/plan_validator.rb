module Boards
  module AdminBuilder
    # Rejects the authoring mistakes that produce a sparse or broken board set,
    # before anything is resolved or written. Returns an array of
    # human-readable problems; empty means the plan is safe to build.
    #
    # Two rules carry the weight:
    #
    #   * **The word list must be within `TILE_COUNT_TOLERANCE` of the page's
    #     tile count, and that count must fill whole rows.** Rows are never stored
    #     (`Board#rows_for_screen_size` derives them from the tiles), so a
    #     partial final row doesn't shorten the board — it leaves conspicuous
    #     empty cells at the right end of the last row, which reads as broken on
    #     a classroom TV.
    #   * **Every page shares the root's grid.** A communicator moving from the
    #     root into a folder page shouldn't have the cell size change under their
    #     finger, and a uniform set prints as one job instead of N. A page that
    #     can't fill the grid on good words should have its remit widened or be
    #     merged into a sibling — not shrunk.
    #
    # Both have an explicit, unticked escape hatch rather than being advisory.
    class PlanValidator
      # A word list within this many tiles of the target is accepted as-is.
      # Deliberately generous: the board is built from the words actually
      # written, so a near-miss is a cosmetic gap at the end of the last row —
      # not a reason to block a build. A tight tolerance turned every draft into
      # a counting exercise.
      TILE_COUNT_TOLERANCE = 20

      def initialize(pages:, allow_partial_row: false, allow_mixed_grids: false)
        @pages = Array(pages)
        @allow_partial_row = allow_partial_row
        @allow_mixed_grids = allow_mixed_grids
      end

      def call
        return ["Add a word list."] if pages.empty?

        problems = key_problems
        # A page whose key is broken can't have its links checked coherently.
        return problems if problems.any?

        problems + pages.flat_map { |page| page_problems(page) } + grid_problems + link_problems +
          orphan_problems
      end

      private

      attr_reader :pages, :allow_partial_row, :allow_mixed_grids

      def root_page = pages.first

      def multi_page? = pages.size > 1

      # Only prefix messages with a page name when there is more than one page,
      # so a single-board build reads exactly as it did before child pages
      # existed.
      def label_for(page)
        return nil unless multi_page?

        page[:name].presence || page[:key]
      end

      # Page messages are authored lowercase so they read as a clause after the
      # page name ("Food: 1 words for a 2×2 grid"). With no prefix they are the
      # whole sentence, so the first letter is restored — a single-board build
      # reads exactly as it did before pages existed.
      def prefixed(page, message)
        name = label_for(page)
        return "#{name}: #{message}" if name

        message.sub(/\A./, &:upcase)
      end

      def key_problems
        problems = []
        children = pages.drop(1)

        children.each_with_index do |page, index|
          position = index + 1
          if page[:key].blank?
            problems << "Page #{position} needs a key — it's how a tile points at the page."
          elsif page[:key] == Plan::ROOT_KEY
            problems << "Page #{position} can't use the key “#{Plan::ROOT_KEY}” — that's the main board."
          elsif !page[:key].match?(/\A[a-z0-9_]+\z/)
            problems << "Page key “#{page[:key]}” must be lowercase letters, numbers and underscores."
          end
        end

        dupes = children.map { |page| page[:key] }.reject(&:blank?).tally.select { |_, n| n > 1 }.keys.sort
        problems << "Duplicate page keys: #{dupes.join(", ")}." if dupes.any?

        problems
      end

      def page_problems(page)
        problems = []
        problems << prefixed(page, "give the page a name.") if multi_page? && page[:name].blank?
        problems.concat(count_problems(page))
        problems.concat(label_problems(page))
        problems.concat(part_of_speech_problems(page))
        problems
      end

      def count_problems(page)
        columns = page[:columns].to_i
        wanted = page[:tile_count].to_i
        return [prefixed(page, "set both a column count and a tile count.")] if columns < 1 || wanted < 1

        tiles = page[:tiles]
        return [prefixed(page, "add at least one word.")] if tiles.empty?

        count_mismatch(page, tiles.size, wanted) + partial_row_problems(page, columns, wanted)
      end

      def count_mismatch(page, written, wanted)
        diff = written - wanted
        return [] if diff.abs <= TILE_COUNT_TOLERANCE

        verb = diff.positive? ? "Remove #{diff}" : "Add #{-diff}"
        [prefixed(page, "#{written} words for a #{wanted}-tile board (needs to be within " \
                        "#{TILE_COUNT_TOLERANCE} of #{wanted}). #{verb} to land on #{wanted} exactly. " \
                        "Change the tile count if the board should be a different size.")]
      end

      # The dead-cell rail, moved off the word list and onto the size itself: a
      # tile count that isn't a whole number of rows leaves empty cells at the
      # right end of the last row no matter how well the words are chosen.
      def partial_row_problems(page, columns, wanted)
        return [] if allow_partial_row || (wanted % columns).zero?

        full = (wanted / columns) * columns
        [prefixed(page, "#{wanted} tiles across #{columns} columns leaves #{wanted - full} in a partial " \
                        "last row, which reads as dead cells. Use #{full} or #{full + columns} — or tick " \
                        "“allow a partial row” if you meant it.")]
      end

      def label_problems(page)
        labels = page[:tiles].map { |tile| tile[:label].to_s.strip }
        problems = []
        problems << prefixed(page, "every tile needs a word — one line is empty.") if labels.any?(&:blank?)

        keys = labels.reject(&:blank?).map(&:downcase)
        dupes = keys.tally.select { |_, count| count > 1 }.keys.sort
        if dupes.any?
          problems << prefixed(page, "duplicate words: #{dupes.join(", ")}. " \
                                     "Each one costs a cell and buys nothing.")
        end

        problems
      end

      def part_of_speech_problems(page)
        bad = page[:tiles].filter_map do |tile|
          pos = tile[:part_of_speech].presence || "default"
          pos unless ColorHelper::PARTS_OF_SPEECH.include?(pos.to_s)
        end.uniq.sort

        return [] if bad.empty?

        [prefixed(page, "unknown part of speech: #{bad.join(", ")}. " \
                        "Use one of: #{ColorHelper::PARTS_OF_SPEECH.join(", ")}.")]
      end

      def grid_problems
        return [] if allow_mixed_grids || !multi_page?

        root_grid = [root_page[:columns].to_i, root_page[:tile_count].to_i]

        pages.drop(1).filter_map do |page|
          next if page[:inherits_grid]

          grid = [page[:columns].to_i, page[:tile_count].to_i]
          next if grid == root_grid

          "#{label_for(page)}: grid #{grid[0]} columns / #{grid[1]} tiles differs from the main board's " \
            "#{root_grid[0]} columns / #{root_grid[1]} tiles. Every page in a set shares the main board's grid. " \
            "If this page can't fill it on good words, widen its remit, merge it into a sibling, or " \
            "cut the folder tile — don't shrink it. Tick “allow mixed grids” only if you meant it."
        end
      end

      def link_problems
        known = pages.map { |page| page[:key] }.to_set

        pages.flat_map do |page|
          page[:tiles].filter_map do |tile|
            target = tile[:links_to].presence
            next if target.nil? || known.include?(target)

            prefixed(page, "tile “#{tile[:label]}” opens page “#{target}”, which doesn't exist.")
          end
        end
      end

      # The other direction, and the one that actually shipped broken sets: a
      # page nothing opens still builds and still publishes, so it goes live at
      # its own /pb/ slug with no way for a communicator to reach it.
      # Boards::AdminBuilder::FolderTiles writes the missing door on every form
      # round-trip, so in practice this fires only for a page whose key never
      # made it that far — it is the backstop, not the mechanism.
      def orphan_problems
        return [] unless multi_page?

        linked = pages.flat_map { |page| page[:tiles] }.filter_map { |tile| tile[:links_to].presence }.to_set

        pages.drop(1).filter_map do |page|
          next if linked.include?(page[:key])

          "#{label_for(page)}: nothing opens this page. Add a tile to the main board with " \
            "“#{Boards::AdminBuilder::WordList::LINK_TOKEN}#{page[:key]}”, or remove the page."
        end
      end
    end
  end
end
