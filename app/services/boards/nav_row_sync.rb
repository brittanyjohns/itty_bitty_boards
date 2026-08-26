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
  # Idempotent: folder tiles this service owns carry data["nav_tile"] = true,
  # word tiles data["nav_word"] = true.
  #
  # **A nav region holds WORDS as well as folders, and the two are not
  # interchangeable.** The authored row is `this | People | … | More | that` —
  # the two determiners at its ends are vocabulary that happens to sit in the
  # nav row, and they are reproduced on every page for the same motor-planning
  # reason the folders are. Treating them as folders wrote a SECOND `this` and
  # `that` onto every child page (the authored one was relocated into the
  # content area as a colliding occupant, then a fresh nav copy was created at
  # its cell) — and the copy carried `mute_name`, which is what makes
  # `BoardImage#door_tile?` true, so the tile in the nav row was a silent door
  # and the speaking one had wandered. Hence `nav_word`: same ownership and
  # idempotency, none of the door/back semantics.
  class NavRowSync
    MAX_DEPTH = 2
    NAV_TILE_KEY = "nav_tile".freeze
    NAV_WORD_KEY = "nav_word".freeze

    Result = Struct.new(:boards_synced, :tiles_written, :folders_deleted,
                        :words_relocated, :words_deduped, keyword_init: true)

    def self.call(root, dry_run: false)
      new(root, dry_run: dry_run).call
    end

    def initialize(root, dry_run: false)
      @root = root
      @dry_run = dry_run
      @result = Result.new(boards_synced: 0, tiles_written: 0,
                           folders_deleted: 0, words_relocated: 0,
                           words_deduped: 0)
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
      set_boards.reject { |b| b.id == @root.id }
    end

    def set_boards
      @set_boards ||= Boards::PredictiveLinkSet
        .collect(@root, max_depth: MAX_DEPTH, exclude: ->(b) { b.user_id != @root.user_id })
    end

    def sync_child!(child)
      @result.boards_synced += 1

      if @dry_run
        @result.tiles_written += region.cells.size
        return
      end

      child.update_column(:large_screen_columns, @root.large_screen_columns) if @root.large_screen_columns.to_i.positive?

      collapse_nav_word_duplicates!(child)
      evict_occupants!(child)
      drop_orphaned_nav_tiles!(child)
      region.cells.each { |cell| upsert_nav_tile!(child, cell) }
      ensure_home_tile!(child)

      child.board_images.reset
      Boards::LayoutRepacker.resync_board_layout!(child)
    end

    # EVERY page in the set gets a one-tap way home. A page whose name is in the
    # nav region gets it from its SELF tile (see #upsert_nav_tile!) — but a page
    # Boards::FolderPlacer tucked into the "More" drawer has no nav cell of its
    # own, so nothing above would give it one. Give it the same anchor
    # explicitly: a tile carrying the page's name that opens the root.
    #
    # Runs after #evict_occupants!, which destroys any child folder tile linking
    # back to the root — an anchor written earlier in the build wouldn't survive.
    def ensure_home_tile!(child)
      # A tile pointing at its OWN board is never navigation — BoardImage#is_dynamic?
      # is false for one, so it renders as a silent word tile with no link badge.
      # #children already rejects the root; this makes it impossible rather than
      # merely unreached.
      return if child.id == @root.id
      return if child.board_images.reload.any? { |bi| bi.predictive_board_id == @root.id }

      # An anchor is chrome, and chrome never displaces vocabulary. The authored
      # Core 60/84 grids are full, so a page cloned from one has nowhere to put
      # this: adding it anyway grew the board past its authored rows (defeating
      # `disable_scroll`) or, where a layout overlap had left a phantom hole,
      # dropped it into a cell the grid was already double-booking. The page is
      # still reachable — its folder tile opens it, and every nav cell on it
      # leads back into the set.
      if free_content_cell(child).nil?
        Rails.logger.info(
          "[NavRowSync] board #{child.id} (#{child.name}): no free cell for a way-home tile; skipped",
        )
        return
      end

      image = Boards::ImageResolver.resolve(child.name, owner: child.user)
      board_image = child.add_image(image.id)
      return if board_image.nil?

      board_image.update!(
        label: child.name,
        display_label: child.name,
        predictive_board_id: @root.id,
        # Flagged like a nav tile because that is what it is — navigation chrome
        # this service owns, not vocabulary. Every consumer that already filters
        # `nav_tile` (specs counting a page's real content, callers reading a
        # page's words) gets it right for free. No "mute_name": like a self tile,
        # the way home speaks its own label.
        data: (board_image.data || {}).merge(NAV_TILE_KEY => true).except("mute_name"),
      )
      place_home_tile!(child, board_image)
      @result.tiles_written += 1
    end

    # The way home goes WHERE THE WAY IN WAS: the same cell as the folder tile
    # that opens this page. A page in the nav region gets that for free — its
    # self tile is written at the root's own cell (see #upsert_nav_tile!) — but
    # a drawer-tucked page's anchor would otherwise land in the first free cell,
    # somewhere different on every page.
    #
    # Swap rather than insert: the occupant takes the cell the anchor would have
    # been given, so nothing is dropped and no hole opens up.
    def place_home_tile!(child, board_image)
      cell = mirrored_cell(child, except: board_image.id)
      return relocate!(child, board_image) if cell.nil?

      # EVERY occupant, not the first one. A cell can already hold two tiles —
      # a stacked layout is exactly the bug that leaves an authored grid looking
      # like it has room — and relocating one of them still leaves the anchor
      # sharing a cell with the other.
      occupants = occupants_at(child, cell, except: board_image.id)
      write_cell!(board_image, cell[0], cell[1])
      occupants.each { |occupant| relocate!(child, occupant) }
    end

    # The cell of the tile that links to this page, clamped into its grid.
    #
    # The linking tile usually lives on the DRAWER board, not the root, and a
    # drawer's content area can be taller than this page's — so a mirrored cell
    # inside the nav region is refused outright rather than clamped into it,
    # where it would fight the nav tiles this service owns.
    def mirrored_cell(child, except:)
      linker = BoardImage.where(board_id: set_boards.map(&:id), predictive_board_id: child.id)
                         .where.not(id: except)
                         .reorder(nil)
                         .find { |bi| bi.layout.is_a?(Hash) && bi.layout["lg"].is_a?(Hash) }
      return nil if linker.nil?

      cell = linker.layout["lg"]
      columns = [child.large_screen_columns.to_i, 1].max
      y = cell["y"].to_i
      return nil if y >= region.top_y

      [[cell["x"].to_i, columns - 1].min.clamp(0, columns - 1), y]
    end

    def occupants_at(child, cell, except:)
      child.board_images.reload.select do |bi|
        next false if bi.id == except

        at = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        at.present? && at["x"].to_i == cell[0] && at["y"].to_i == cell[1]
      end
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
        next if owned?(bi) # ours; upsert handles it

        if bi.predictive_board_id.present? &&
           (nav_labels.include?(bi.label.to_s.downcase) || bi.predictive_board_id == @root.id)
          bi.destroy!
          @result.folders_deleted += 1
          next
        end

        # The page's authored copy of a nav-row WORD (`this`, `that`). It is the
        # tile the upsert adopts, so leave it alone — relocating it into the
        # content area is exactly what produced the duplicate.
        next if nav_word_labels.include?(bi.label.to_s.downcase)

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
      cell = free_content_cell(child, except: board_image.id)
      return write_cell!(board_image, cell[0], cell[1]) if cell

      shift_region_down!(child)
      write_cell!(board_image, 0, region.top_y)
    end

    # First free cell strictly above the nav region, or nil when the content
    # area is full. Occupancy is DISTINCT cells (#occupied_cells is a Set), so
    # two tiles stacked on one cell read as one occupied cell — never as one
    # occupied and one free, which is how a stacked seed cell used to hand a
    # placement a hole that wasn't there.
    def free_content_cell(child, except: nil)
      columns = [child.large_screen_columns.to_i, 1].max
      occupied = occupied_cells(child, except: except)

      (0...region.top_y).each do |y|
        (0...columns).each do |x|
          return [x, y] unless occupied.include?([x, y])
        end
      end

      nil
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
        next unless owned?(bi)
        next if labels.include?(bi.label.to_s.downcase)
        # A drawer-tucked page's way home (#ensure_home_tile!) is flagged like a
        # nav tile but its label is deliberately NOT in the region. Keep it, or
        # every sync would drop and re-add it.
        next if bi.predictive_board_id == @root.id

        bi.destroy!
        @result.folders_deleted += 1
      end
    end

    def upsert_nav_tile!(child, cell)
      self_tile = cell.label.to_s.strip.casecmp?(child.name.to_s.strip)
      word_cell = !self_tile && cell.target_board_id.blank?

      existing = child.board_images.reload.find do |bi|
        next false unless bi.label.to_s.casecmp?(cell.label)
        # A word cell also adopts the page's own AUTHORED copy of the word —
        # the seed .obf carries `this`/`that` in every page's nav row, and
        # creating a second one is the duplicate this service used to produce.
        next true if word_cell && bi.predictive_board_id.blank?

        owned?(bi)
      end

      board_image = existing || begin
        image = Boards::ImageResolver.resolve(cell.label, owner: child.user)
        child.add_image(image.id)
      end
      return if board_image.nil?

      own_key = word_cell ? NAV_WORD_KEY : NAV_TILE_KEY
      data = (board_image.data || {}).except(NAV_TILE_KEY, NAV_WORD_KEY).merge(own_key => true)
      # Folder tiles navigate silently; the self-tile speaks its own label, and
      # a nav-row word is vocabulary — it must speak or it isn't a word.
      data = (self_tile || word_cell) ? data.except("mute_name") : data.merge("mute_name" => true)

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

    # Labels the region carries as WORDS rather than folders (`this`, `that`).
    # A cell pointing at no board is a word — except the page's own self tile,
    # which is resolved per-child in #upsert_nav_tile!.
    def nav_word_labels
      @nav_word_labels ||= region.cells.reject(&:target_board_id)
                                 .map { |c| c.label.to_s.downcase }.to_set
    end

    def owned?(board_image)
      data = board_image.data
      return false unless data.is_a?(Hash)

      data[NAV_TILE_KEY] == true || data[NAV_WORD_KEY] == true
    end

    # Heals the pages an earlier sync duplicated: one authored `this` in the
    # content area and one muted nav copy in the nav row. Keeps the authored
    # tile (lowest position) — the upsert then adopts and re-flags it.
    #
    # Scoped to nav-word labels rather than delegating to Boards::TileDeduper:
    # a page's other duplicates are a seeding concern, and this runs over every
    # page of every built set.
    def collapse_nav_word_duplicates!(child)
      child.board_images.reload
           .select { |bi| bi.predictive_board_id.blank? && nav_word_labels.include?(bi.label.to_s.downcase) }
           .group_by { |bi| bi.label.to_s.downcase }
           .each_value do |tiles|
             next if tiles.size < 2

             tiles.sort_by { |bi| [bi.position || Float::INFINITY, bi.id] }.drop(1).each do |bi|
               bi.destroy!
               @result.words_deduped += 1
             end
           end
    end
  end
end
