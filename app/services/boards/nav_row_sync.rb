module Boards
  # Projects a built set's NAV REGION (Boards::NavRegion) onto every page in
  # the set, so a category is the same reach from anywhere. The tile matching
  # the page you're on links back to the ROOT — the you-are-here anchor and the
  # way home — and is the one nav tile that speaks its label.
  #
  # Authoring the nav row in the seed .obf files (see
  # db/seeds/board_builder_sets/README.md) can only cover the pages that ship
  # IN the seed set. This covers the pages a build ADDS — prebuilt fringe,
  # AI-generated, My Favorites, Phrases, the GLP function boards — and repairs
  # the seeded pages whose nav row went stale when the build grew the root.
  #
  # Idempotent: tiles this service owns carry data["nav_tile"] = true.
  class NavRowSync
    MAX_DEPTH = 2
    NAV_TILE_KEY = "nav_tile".freeze

    Result = Struct.new(:boards_synced, :tiles_written, :folders_deleted,
                        :words_relocated, keyword_init: true)

    def self.call(root, dry_run: false)
      new(root, dry_run: dry_run).call
    end

    def initialize(root, dry_run: false)
      @root = root
      @dry_run = dry_run
      @result = Result.new(boards_synced: 0, tiles_written: 0,
                           folders_deleted: 0, words_relocated: 0)
    end

    def call
      tiles   = Boards::NavRegion.align(Boards::NavRegion.placed_tiles(@root))
      @region = Boards::NavRegion.for_tiles(tiles)
      return @result if @region.empty?

      persist_alignment!(tiles) unless @dry_run
      children.each { |child| sync_child!(child) }
      @result
    end

    private

    attr_reader :region

    # `align` may have rotated the authored nav row back to the bottom; write
    # those new y values onto the root before anything reads its layout again.
    def persist_alignment!(tiles)
      changed = false
      tiles.each do |t|
        bi = BoardImage.find_by(id: t.board_image_id)
        next if bi.nil?

        cell = (bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil) || {}
        next if cell["y"].to_i == t.y

        bi.layout = (bi.layout || {}).merge("lg" => cell.merge("y" => t.y))
        bi.save!
        changed = true
      end
      Boards::LayoutRepacker.resync_board_layout!(@root) if changed
    end

    def children
      Boards::PredictiveLinkSet
        .collect(@root, max_depth: MAX_DEPTH, exclude: ->(b) { b.user_id != @root.user_id })
        .reject { |b| b.id == @root.id }
    end

    def sync_child!(child)
      @result.boards_synced += 1

      if @dry_run
        @result.tiles_written += region.cells.size
        return
      end

      child.update_column(:large_screen_columns, @root.large_screen_columns) if @root.large_screen_columns.to_i.positive?

      evict_occupants!(child)
      drop_orphaned_nav_tiles!(child)
      region.cells.each { |cell| upsert_nav_tile!(child, cell) }

      child.board_images.reset
      Boards::LayoutRepacker.resync_board_layout!(child)
    end

    # Make room for the nav region.
    #
    # A tile is a LEGACY NAV tile — replaced by this sync, so destroyed wherever
    # it sits — only when it is a folder tile AND either carries a nav
    # category's label (the pre-sync copy, often shifted a cell to the left) or
    # links back to the root (the old `Home` way-home tile). Everything else is
    # content: a page's own folder tiles are its reason to exist (the Phrases
    # page links the six gestalt function boards), so a merely-colliding tile is
    # RELOCATED into the content area — word or folder, never dropped.
    def evict_occupants!(child)
      targets = region.cells.map { |c| [c.x, c.y] }.to_set
      nav_labels = region.cells.map { |c| c.label.to_s.downcase }.to_set

      child.board_images.reload.each do |bi|
        next if bi.data&.dig(NAV_TILE_KEY) # ours; upsert handles it

        if bi.predictive_board_id.present? &&
           (nav_labels.include?(bi.label.to_s.downcase) || bi.predictive_board_id == @root.id)
          bi.destroy!
          @result.folders_deleted += 1
          next
        end

        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil?
        next unless targets.include?([cell["x"].to_i, cell["y"].to_i])

        relocate!(child, bi)
        @result.words_relocated += 1
      end
    end

    # First free cell strictly above the nav region. When the content area is
    # full, push the nav region down a row and take the row that frees up, so a
    # relocated tile is never dropped for want of space.
    def relocate!(child, board_image)
      columns = [child.large_screen_columns.to_i, 1].max
      occupied = occupied_cells(child, except: board_image.id)

      (0...region.top_y).each do |y|
        (0...columns).each do |x|
          next if occupied.include?([x, y])

          write_cell!(board_image, x, y)
          return
        end
      end

      shift_region_down!(child)
      write_cell!(board_image, 0, region.top_y)
    end

    def shift_region_down!(child)
      child.board_images.reload.each do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil? || cell["y"].to_i < region.top_y

        write_cell!(bi, cell["x"].to_i, cell["y"].to_i + 1)
      end
    end

    def occupied_cells(child, except: nil)
      child.board_images.reload.each_with_object(Set.new) do |bi, acc|
        next if bi.id == except

        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        acc << [cell["x"].to_i, cell["y"].to_i] if cell
      end
    end

    def write_cell!(board_image, x, y)
      cell = (board_image.layout.is_a?(Hash) ? board_image.layout["lg"] : nil) || {}
      board_image.layout = (board_image.layout || {}).merge(
        "lg" => cell.merge("i" => board_image.id.to_s, "x" => x, "y" => y,
                           "w" => [cell["w"].to_i, 1].max, "h" => [cell["h"].to_i, 1].max),
      )
      board_image.save!
    end

    # A nav tile we own whose label left the region (the root dropped a page).
    def drop_orphaned_nav_tiles!(child)
      labels = region.cells.map { |c| c.label.downcase }.to_set

      child.board_images.reload.each do |bi|
        next unless bi.data&.dig(NAV_TILE_KEY)
        next if labels.include?(bi.label.to_s.downcase)

        bi.destroy!
        @result.folders_deleted += 1
      end
    end

    def upsert_nav_tile!(child, cell)
      existing = child.board_images.reload.find do |bi|
        bi.data&.dig(NAV_TILE_KEY) && bi.label.to_s.casecmp?(cell.label)
      end

      board_image = existing || begin
        image = Boards::ImageResolver.resolve(cell.label, owner: child.user)
        child.add_image(image.id)
      end
      return if board_image.nil?

      self_tile = cell.label.to_s.strip.casecmp?(child.name.to_s.strip)
      data = (board_image.data || {}).merge(NAV_TILE_KEY => true)
      # Folder tiles navigate silently; the self-tile speaks its own label.
      data = self_tile ? data.except("mute_name") : data.merge("mute_name" => true)

      board_image.update!(
        # BoardImage#set_defaults derives the label from the resolved Image
        # (often lowercase art), so the authored name is re-pinned explicitly.
        label: cell.label,
        display_label: cell.label,
        predictive_board_id: self_tile ? @root.id : cell.target_board_id,
        data: data,
      )
      write_cell!(board_image, cell.x, cell.y)
      @result.tiles_written += 1
    end
  end
end
