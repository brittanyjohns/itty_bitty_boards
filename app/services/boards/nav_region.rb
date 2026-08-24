module Boards
  # Derives a built set's NAV REGION from its root board's `lg` layout.
  #
  # The nav region is the strip of category tiles reproduced cell-for-cell on
  # every page of the set, so a category is the same reach no matter which page
  # you're on (motor planning — an AAC user learns WHERE a word is). See
  # db/seeds/board_builder_sets/README.md for the authoring rule this mirrors.
  #
  # Pure query: reads layouts, returns structs, never writes. Boards::NavRowSync
  # is what persists anything.
  module NavRegion
    module_function

    # A build appends new folder tiles onto a new row BELOW the authored nav
    # row (Board#add_image fills the first open cell, and the authored Core
    # 60/84 grids are full). We allow at most this many such rows to join the
    # nav region; the rest stay reachable from the home board only.
    MAX_ADDED_ROWS = 1

    Tile = Struct.new(:board_image_id, :x, :y, :w, :h, :label, :target_board_id,
                      keyword_init: true)

    Result = Struct.new(:rows, :cells, keyword_init: true) do
      def empty? = cells.empty?
      def row_count = rows.size
      def top_y = rows.first
    end

    EMPTY = Result.new(rows: [], cells: [])

    # The tiles this board reserves for NAVIGATION — the strip
    # Boards::NavRowSync reproduces cell-for-cell on every page of a set.
    #
    # A re-layout must write these back at their own cells rather than permute
    # them with the words. The strip is a motor path a communicator has learned,
    # and it is identical on every OTHER page of the set — none of which a
    # re-layout of one board touches — so scattering it here breaks the set even
    # though only one board changed.
    #
    # Two ways to know, in order of precision:
    #
    #   - A synced PAGE carries the flags NavRowSync owns, so the region is
    #     exactly those tiles. No geometry, no guessing.
    #   - A set ROOT carries no flags — the sync writes children, and the root's
    #     own row is authored in the seed .obf — so it falls back to the
    #     geometric read, gated on the two pins that mean "top of a set":
    #     `builder_root?` (Board Builder) and `pinned_main_board?` (an imported
    #     OBF/OBZ set, per Boards::ImportedSetClassifier).
    #
    # Anything else — an ordinary board that happens to hold a folder tile —
    # gets EMPTY. The geometric read calls "the row holding the most folder
    # tiles" the nav row, which is only true of a set; on a board of categories
    # it would pin an arbitrary row. Such a board keeps the pre-existing
    # behaviour, where doors band last (Boards::TileArrangement::LINK_BAND) and
    # land in the closing cells on their own.
    def for_board(board)
      flagged = flagged_region(board)
      return flagged unless flagged.empty?
      return EMPTY unless set_root?(board)

      for_root(board)
    end

    # The region as the tiles NavRowSync flagged, at their stored lg cells.
    # Rows are whatever rows those tiles occupy — a synced page's strip is
    # already where the sync put it, so there is nothing to infer.
    def flagged_region(board)
      flags = [Boards::NavRowSync::NAV_TILE_KEY, Boards::NavRowSync::NAV_WORD_KEY]

      owned = board.board_images.filter_map do |bi|
        data = bi.data
        next unless data.is_a?(Hash) && flags.any? { |flag| data[flag] == true }

        bi.id
      end.to_set
      return EMPTY if owned.empty?

      tiles = placed_tiles(board).select { |t| owned.include?(t.board_image_id) }
      return EMPTY if tiles.empty?

      Result.new(rows: tiles.map(&:y).uniq.sort, cells: tiles)
    end

    # The top of a set, and so a board whose bottom row is navigation rather
    # than vocabulary. Both pins are written by exactly one caller each
    # (BuildBoardSetJob, Boards::ImportedSetClassifier), which is what makes
    # them safe to key the geometric read on.
    def set_root?(board)
      board.builder_root? || board.pinned_main_board?
    end

    def for_root(root)
      for_tiles(align(placed_tiles(root)))
    end

    # Every tile on the board that has an lg cell, in authored order.
    def placed_tiles(root)
      root.board_images.order(:position).filter_map do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil?

        Tile.new(
          board_image_id: bi.id,
          x: cell["x"].to_i,
          y: cell["y"].to_i,
          w: [cell["w"].to_i, 1].max,
          h: [cell["h"].to_i, 1].max,
          label: bi.label.to_s,
          target_board_id: bi.predictive_board_id,
        )
      end
    end

    # The authored nav row: the row holding the most folder tiles. Ties resolve
    # to the LOWEST row index, so a pathological build that added more folder
    # tiles than the authored row holds still can't steal the title.
    def authored_nav_y(tiles)
      folders = tiles.select(&:target_board_id)
      return nil if folders.empty?

      folders.group_by(&:y).max_by { |y, group| [group.size, -y] }.first
    end

    # Rotate the authored nav row back to the bottom: it stays the last row
    # (so `People` never moves), and the build's added rows lift to sit above
    # it. Returns a new tile list; the input is not mutated.
    def align(tiles)
      return tiles if tiles.empty?

      nav_y = authored_nav_y(tiles)
      return tiles if nav_y.nil?

      last_y = tiles.map(&:y).max
      return tiles if nav_y == last_y

      tiles.map do |t|
        new_y =
          if t.y == nav_y then last_y
          elsif t.y > nav_y then t.y - 1
          else t.y
          end

        Tile.new(**t.to_h.merge(y: new_y))
      end
    end

    # Nav rows are the bottom row, plus (going up, capped at MAX_ADDED_ROWS)
    # each immediately preceding row whose occupied cells are ALL folder tiles.
    # That "all folders" test is what keeps a content row holding one stray
    # folder tile — Core 84's `More` — out of the region; it's pinned instead.
    def for_tiles(tiles)
      return EMPTY if tiles.empty? || tiles.none?(&:target_board_id)

      by_row = tiles.group_by(&:y)
      last_y = by_row.keys.max
      rows = [last_y]

      MAX_ADDED_ROWS.times do
        candidate = rows.first - 1
        row = by_row[candidate]
        break if row.nil? || row.empty?
        break unless row.all?(&:target_board_id)

        rows.unshift(candidate)
      end

      top_y = rows.first
      cells = tiles.select { |t| rows.include?(t.y) || (t.y < top_y && t.target_board_id) }

      Result.new(rows: rows, cells: cells)
    end
  end
end
