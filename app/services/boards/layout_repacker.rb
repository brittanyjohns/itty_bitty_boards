module Boards
  # Pulls DISPLACED tiles back into a clean grid, for each screen size: tiles
  # stored PAST the configured column count (off-grid), and tiles that OVERLAP a
  # cell an earlier tile already claims. Only the displaced tiles move —
  # authored/earlier in-grid tiles keep their exact x/y — and each is placed into
  # the first free cell (filling in-grid gaps before growing a new row). Mirrors
  # the frontend `repackLayout` (itty-bitty-frontend
  # src/components/images/native/nativeLayoutMath.ts).
  #
  # Why this exists: a builder/seed bug can leave a tile at e.g. x=13 on a
  # 12-column board (off-grid) — the editor renders through react-grid-layout,
  # which keeps the grid at the configured `cols`, but the native Speak view sized
  # the grid by the tile extent and so silently widened to 14 columns, making
  # Speak look different from every other view. The same class of bug can park two
  # tiles on the SAME cell (core-84 "wait" on "again"), rendering one hidden
  # behind the other ("84 looks like 82"). TileDeduper removes off-grid/overlapping
  # DUPLICATES; this is the safety net for genuine non-duplicate displaced tiles.
  module LayoutRepacker
    module_function

    SCREENS = %w[lg md sm].freeze

    # Repacks every screen size and resyncs the board's denormalized layout.
    # Returns the number of tiles moved across all screens (0 when clean).
    # dry_run: report-only — counts what WOULD move without persisting.
    # ignore_ids: board_image ids to skip — used by a dry-run preview to exclude
    # tiles that the dedupe pass will remove first, so an off-grid duplicate is
    # not double-counted as an overflow tile.
    def repack!(board, dry_run: false, ignore_ids: [])
      ignore = ignore_ids.to_a.map(&:to_i).to_set
      moved = SCREENS.sum { |screen| repack_screen!(board, screen, dry_run: dry_run, ignore: ignore) }
      resync_board_layout!(board) if moved.positive? && !dry_run
      moved
    end

    # Returns the number of displaced tiles moved for one screen size. A tile is
    # "displaced" when it sits OFF-GRID (x + w past the column count) OR OVERLAPS
    # a cell an earlier (reading-order) tile already claims — e.g. a builder/seed
    # bug that parked two tiles on the same cell (core-84 "wait" on "again"),
    # leaving one rendered hidden behind the other. Earlier tiles keep their exact
    # authored cell; only the displaced ones move, into the first free cells.
    def repack_screen!(board, screen, dry_run: false, ignore: Set.new)
      columns = column_count(board, screen)
      return 0 if columns < 1

      displaced, occupied, fits = survey(board, screen, columns, ignore: ignore)

      return displaced.size if displaced.empty? || dry_run

      base_y = fits.map { |_bi, c| c["y"].to_i + tile_h(c) }.max || 0

      cx = 0
      cy = base_y
      row_h = 0
      # Shelf-pack displaced tiles in reading order below the fitting tiles, just
      # like the frontend repackLayout — so editor and Speak agree on the result.
      displaced.sort_by { |_bi, c| [c["y"].to_i, c["x"].to_i] }.each do |bi, cell|
        w = [tile_w(cell), columns].min
        h = tile_h(cell)
        if cx + w > columns
          cx = 0
          cy += row_h
          row_h = 0
        end
        bi.layout[screen] = cell.merge("i" => bi.id.to_s, "x" => cx, "y" => cy, "w" => w, "h" => h)
        bi.save!
        cx += w
        row_h = [row_h, h].max
      end

      displaced.size
    end

    # Splits one screen's tiles into the ones that FIT (each claiming its own
    # cells) and the DISPLACED ones — off-grid, or overlapping a cell an earlier
    # tile already claims. Reading order, so the authored/earlier tile wins a
    # contested cell. Returns [displaced, occupied, fits].
    def survey(board, screen, columns, ignore: Set.new)
      items = board.board_images.order(:position).to_a.filter_map do |bi|
        next if ignore.include?(bi.id)

        cell = bi.layout.is_a?(Hash) ? bi.layout[screen] : nil
        cell.nil? ? nil : [bi, cell]
      end

      occupied = Set.new
      displaced = []
      fits = []
      items.each do |bi, c|
        cells = cell_coords(c, columns)
        if off_grid?(c, columns) || cells.any? { |xy| occupied.include?(xy) }
          displaced << [bi, c]
        else
          cells.each { |xy| occupied << xy }
          fits << [bi, c]
        end
      end

      [displaced, occupied, fits]
    end
    private_class_method :survey

    # Un-stack WITHOUT growing the grid wherever that is possible: a displaced
    # tile is moved into the first FREE cell inside the board's current extent,
    # in reading order. Only what still doesn't fit falls through to #repack!.
    #
    # This is the repair for an AUTHORED grid — a seeded Core 60/84 page or a
    # clone of one — where the tile count and the cell count are meant to match
    # exactly and `settings["disable_scroll"]` locks the board to one screen.
    # #repack! is the other case: it mirrors the frontend `repackLayout`, which
    # shelf-packs displaced tiles BELOW everything that fits. Doing that to a
    # full 84-cell board turns "two tiles on one cell" into "eight rows", which
    # silently defeats disable_scroll — the exact damage this exists to repair.
    #
    # Only 1x1 tiles are gap-filled; a wider tile needs adjacent free cells and
    # is left to the shelf-pack. Authored grids are all 1x1.
    def unstack!(board, dry_run: false)
      moved = SCREENS.sum { |screen| unstack_screen!(board, screen, dry_run: dry_run) }
      resync_board_layout!(board) if moved.positive? && !dry_run
      moved
    end

    def unstack_screen!(board, screen, dry_run: false)
      columns = column_count(board, screen)
      return 0 if columns < 1

      displaced, occupied, = survey(board, screen, columns)
      return displaced.size if displaced.empty? || dry_run

      rows = occupied.map { |(_x, y)| y }.max.to_i + 1
      remaining = []

      displaced.sort_by { |_bi, c| [c["y"].to_i, c["x"].to_i] }.each do |bi, cell|
        gap = tile_w(cell) == 1 && tile_h(cell) == 1 ? first_free_cell(occupied, columns, rows) : nil
        if gap.nil?
          remaining << [bi, cell]
          next
        end

        occupied << gap
        bi.layout[screen] = cell.merge("i" => bi.id.to_s, "x" => gap[0], "y" => gap[1], "w" => 1, "h" => 1)
        bi.save!
      end

      # Anything the grid genuinely had no room for keeps the existing behaviour.
      repack_screen!(board, screen) if remaining.any?

      displaced.size
    end

    # First unoccupied cell in reading order inside `columns` x `rows`, or nil.
    def first_free_cell(occupied, columns, rows)
      rows.times do |y|
        columns.times do |x|
          return [x, y] unless occupied.include?([x, y])
        end
      end

      nil
    end
    private_class_method :first_free_cell

    # The grid cells a tile occupies at its current x/y, width clamped to columns.
    def cell_coords(cell, columns)
      x = cell["x"].to_i
      y = cell["y"].to_i
      w = [tile_w(cell), columns].min
      h = tile_h(cell)
      h.times.flat_map { |dy| w.times.map { |dx| [x + dx, y + dy] } }
    end
    private_class_method :cell_coords

    def off_grid?(cell, columns)
      (cell["x"].to_i + tile_w(cell)) > columns
    end
    private_class_method :off_grid?

    # Rebuild board.layout from the (now corrected) per-tile layouts, for every
    # screen, keyed by board_image id — matching Board#update_board_layout's
    # shape but without wiping the other screen sizes.
    def resync_board_layout!(board)
      new_layout = {}
      ordered = board.board_images.order(:position)
      SCREENS.each do |screen|
        screen_layout = {}
        ordered.each do |bi|
          cell = bi.layout.is_a?(Hash) ? bi.layout[screen] : nil
          next if cell.nil?

          screen_layout[bi.id.to_s] = cell.merge("i" => bi.id.to_s)
        end
        new_layout[screen] = screen_layout unless screen_layout.empty?
      end
      board.update_column(:layout, new_layout)
    end

    def column_count(board, screen)
      explicit =
        case screen
        when "sm" then board.small_screen_columns
        when "md" then board.medium_screen_columns
        else board.large_screen_columns
        end
      cols = explicit.to_i
      return cols if cols >= 1

      # No explicit count: derive md/sm from the authored lg count so the grid
      # we repack into matches what the viewer/editor size to (ScreenColumns).
      lg = board.large_screen_columns.to_i
      lg = board.number_of_columns.to_i if lg < 1
      lg = 12 if lg < 1
      Boards::ScreenColumns.derive(lg, screen)
    end
    private_class_method :column_count

    def tile_w(cell)
      [cell["w"].to_i, 1].max
    end
    private_class_method :tile_w

    def tile_h(cell)
      [cell["h"].to_i, 1].max
    end
    private_class_method :tile_h
  end
end
