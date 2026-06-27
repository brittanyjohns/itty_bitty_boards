module Boards
  # Pulls tiles that are stored PAST the configured column count back inside the
  # grid, for each screen size. Mirrors the frontend `repackLayout`
  # (itty-bitty-frontend src/components/images/native/nativeLayoutMath.ts): only
  # the overflowing tiles move — authored in-grid tiles keep their exact x/y —
  # and the overflow is shelf-packed into the first empty rows below them.
  #
  # Why this exists: a builder/seed bug can leave a tile at e.g. x=13 on a
  # 12-column board. The editor renders through react-grid-layout, which keeps
  # the grid at the configured `cols`, but the native Speak view sized the grid
  # by the tile extent and so silently widened to 14 columns — making Speak look
  # different from every other view. TileDeduper removes off-grid DUPLICATES;
  # this is the safety net for a genuine non-duplicate overflow tile.
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

    # Returns the number of overflow tiles moved for one screen size.
    def repack_screen!(board, screen, dry_run: false, ignore: Set.new)
      columns = column_count(board, screen)
      return 0 if columns < 1

      items = board.board_images.to_a.filter_map do |bi|
        next if ignore.include?(bi.id)

        cell = bi.layout.is_a?(Hash) ? bi.layout[screen] : nil
        cell.nil? ? nil : [bi, cell]
      end

      overflow = items.select { |_bi, c| (c["x"].to_i + tile_w(c)) > columns }
      return overflow.size if overflow.empty? || dry_run

      fits = items - overflow
      base_y = fits.map { |_bi, c| c["y"].to_i + tile_h(c) }.max || 0

      cx = 0
      cy = base_y
      row_h = 0
      # Shelf-pack overflow tiles in reading order, just like the frontend.
      overflow.sort_by { |_bi, c| [c["y"].to_i, c["x"].to_i] }.each do |bi, cell|
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

      overflow.size
    end

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
