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
