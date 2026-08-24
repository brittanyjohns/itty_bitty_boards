module Boards
  # Decides WHERE a built set's top-level folder tile goes.
  #
  # The authored core grids are completely full — Core 60 is 60 tiles in 60
  # cells, Core 84 is 84 in 84 — so every fringe page a build added used to
  # spill onto a stray row: one orphan tile on its own line (Boards::NavRegion
  # then rotates the authored nav row back under it), a home board that reads
  # "61 tiles", and the loss of the seed's single-screen `disable_scroll`.
  #
  # Instead the overflow is tucked into the set's **"More" drawer**. More is on
  # the nav row of every page in the set, so the page stays two taps from
  # anywhere, and it is authored with two spare rows for exactly this (Core 60's
  # More: 40 tiles in 60 cells, against 50 on every other fringe page). That
  # headroom is the drawer's job — see db/seeds/board_builder_sets/README.md
  # before filling More up like any other page. The authored home grid is never
  # grown while the drawer has room.
  class FolderPlacer
    DRAWER_NAME = "More".freeze

    # destination:
    #   :root   — placed in a genuine open cell on the home grid
    #   :drawer — home grid full; tucked into "More"
    #   :grown  — home grid full and no usable drawer; the home grid grew a row
    Result = Struct.new(:tile, :board, :destination, keyword_init: true)

    def self.place!(root:, owner:, name:, board_id:)
      new(root: root, owner: owner).place!(name: name, board_id: board_id)
    end

    # The board opened by the root's "More" folder tile, scoped to the root's
    # owner so a tile pointing at a shared/admin board can't be written into.
    def self.drawer_for(root)
      tile = root.board_images.where.not(predictive_board_id: nil)
        .detect { |bi| bi.label.to_s.strip.casecmp?(DRAWER_NAME) }
      return nil if tile.nil? || tile.predictive_board_id == root.id

      Board.find_by(id: tile.predictive_board_id, user_id: root.user_id)
    end

    def initialize(root:, owner:)
      @root = root
      @owner = owner
    end

    def place!(name:, board_id:)
      @root.reload

      if @root.open_grid_cells >= 1
        tile = add_tile!(@root, name, board_id)
        return tile && Result.new(tile: tile, board: @root, destination: :root)
      end

      drawer = self.class.drawer_for(@root)
      cell = drawer && drawer_allows?(name) && overflow_cell(drawer)
      if cell
        tile = add_tile!(drawer, name, board_id, cell: cell)
        return tile && Result.new(tile: tile, board: drawer, destination: :drawer)
      end

      # No drawer (the legacy starter trees have none) or no room left in it:
      # grow the home grid rather than drop a page the child asked for.
      # BuildBoardSetJob#allow_scroll_if_grown! clears `disable_scroll` so the
      # new row isn't clipped.
      tile = add_tile!(@root, name, board_id)
      tile && Result.new(tile: tile, board: @root, destination: :grown)
    end

    private

    # Boards::NavRowSync projects the ROOT's nav region onto every page and
    # DESTROYS any folder tile on a child that carries a nav category's label.
    # A page whose name collides with a nav label would therefore be silently
    # orphaned inside the drawer, so it stays on the home board instead.
    def drawer_allows?(name)
      nav_labels = Boards::NavRegion.for_root(@root).cells.map { |c| c.label.to_s.strip.downcase }
      !nav_labels.include?(name.to_s.strip.downcase)
    end

    # Overflow pages read as their own band rather than filling whatever gaps an
    # authored content row happens to leave. So, scanning the rows ABOVE the
    # drawer's nav row top-down, prefer:
    #
    #   1. a row already holding nothing but folder tiles — the band a previous
    #      call started, so successive pages pack left-to-right into one row;
    #   2. the first fully-empty row, left-most cell — a fresh band;
    #   3. any open cell at all, when the drawer is nearly full.
    #
    # nil once the drawer has no room, which sends the caller back to the root.
    def overflow_cell(drawer)
      columns = drawer.large_screen_columns.to_i
      columns = drawer.number_of_columns.to_i if columns < 1
      return nil if columns < 1

      rows = occupied_rows(drawer)
      return nil if rows.empty?

      # Rows strictly above the drawer's own nav row, which is always its
      # BOTTOM row: Boards::NavRowSync projects the root's nav region onto every
      # page at the region's own (bottom-pinned) cells, and the seed .obf files
      # author it there too. Deliberately not NavRegion.authored_nav_y — that
      # picks whichever row holds the most folder tiles, so a band that grew to
      # the nav row's size would steal the title and start overwriting content.
      limit = rows.keys.max
      return nil if limit < 1

      band = (0...limit).find do |y|
        row = rows[y]
        row[:xs].any? && row[:folders_only] && row[:xs].size < columns
      end
      return { "x" => first_open_x(rows[band], columns), "y" => band } if band

      empty_row = (0...limit).find { |y| rows[y][:xs].empty? }
      return { "x" => 0, "y" => empty_row } if empty_row

      (0...limit).each do |y|
        x = first_open_x(rows[y], columns)
        return { "x" => x, "y" => y } if x
      end

      nil
    end

    def first_open_x(row, columns)
      (0...columns).find { |x| !row[:xs].include?(x) }
    end

    # y => { xs: Set of occupied x, folders_only: bool }, read from the tiles'
    # own `lg` cells — never from board.layout, whose accessor rebuilds and
    # writes the column as a side effect.
    def occupied_rows(board)
      rows = Hash.new { |h, k| h[k] = { xs: Set.new, folders_only: true } }

      board.board_images.each do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil?

        x = cell["x"].to_i
        y = cell["y"].to_i
        w = [cell["w"].to_i, 1].max
        h = [cell["h"].to_i, 1].max
        h.times do |dy|
          row = rows[y + dy]
          w.times { |dx| row[:xs] << (x + dx) }
          row[:folders_only] &&= bi.predictive_board_id.present?
        end
      end

      rows
    end

    def add_tile!(board, name, board_id, cell: nil)
      board.reload
      image = Boards::ImageResolver.resolve(name, owner: @owner)
      tile = board.add_image(image.id)
      return nil unless tile

      # BoardImage#set_defaults derives the label from the image, which may be
      # stored under different casing ("animals"); pin the authored folder name.
      tile.update!(predictive_board_id: board_id, label: name, display_label: name)
      pin_cell!(board, tile, cell) if cell
      tile
    end

    # Board#add_image drops the tile in the first open cell; move it to the
    # chosen one and mirror the change into the board's own layout column.
    def pin_cell!(board, tile, cell)
      lg = (tile.layout.is_a?(Hash) ? tile.layout["lg"] : nil) || {}
      tile.layout = (tile.layout || {}).merge(
        "lg" => lg.merge("i" => tile.id.to_s, "x" => cell["x"], "y" => cell["y"], "w" => 1, "h" => 1),
      )
      tile.save!
      board.board_images.reset
      Boards::LayoutRepacker.resync_board_layout!(board)
    end
  end
end
