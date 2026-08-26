# app/services/vocab_sets.rb
#
# Seeds the Board Builder's "robust vocabulary set" templates (Core 60, Core 84)
# from the authored OBF/OBZ source in db/seeds/board_builder_sets/<slug>/.
#
# Each set is imported via ObzImporter as admin (User::DEFAULT_ADMIN_ID) into a
# linked tree of predefined/published boards. NO BoardGroup is created — the set
# is identified by a marker on its ROOT board (Boards::RobustSets). The Board
# Builder then clones the chosen set per user and routes the child's interests
# into the cloned fringe pages.
#
# Driven by lib/tasks/vocab_sets.rake (vocab_sets:seed / vocab_sets:build).
require "zip"

module VocabSets
  SETS_DIR = Rails.root.join("db", "seeds", "board_builder_sets")

  # OBF ids that used to belong to the sets but have been removed from the
  # manifests entirely (no namespaced successor). Listed here so a re-seed
  # cleans up the stale admin-owned boards they created. `keyboard` was dropped
  # in #276 (the Keyboard board/feature was cut). These are bare (un-namespaced)
  # ids from the pre-namespacing collision era — see #277/#278.
  LEGACY_REMOVED_OBF_IDS = %w[keyboard].freeze

  module_function

  # Slugs that have authored source (a manifest.json), optionally filtered by a
  # comma-separated list.
  def available_slugs(filter = nil)
    present = Dir.children(SETS_DIR).select do |name|
      File.file?(SETS_DIR.join(name, "manifest.json"))
    end.sort
    return present if filter.blank?

    wanted = filter.split(",").map(&:strip)
    present & wanted
  end

  # Zip the authored source dir into in-memory .obz bytes (manifest.json +
  # boards/*.obf), preserving relative paths.
  def obz_bytes(slug)
    dir = SETS_DIR.join(slug)
    raise "No source dir for slug #{slug.inspect} at #{dir}" unless File.directory?(dir)

    buffer = Zip::OutputStream.write_buffer do |zos|
      Dir.glob(dir.join("**", "*")).sort.each do |path|
        next unless File.file?(path)

        rel = Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
        zos.put_next_entry(rel)
        zos.write(File.binread(path))
      end
    end
    buffer.rewind
    buffer.read
  end

  def admin
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      raise("Admin user (User::DEFAULT_ADMIN_ID=#{User::DEFAULT_ADMIN_ID}) not found — seed it first")
  end

  # Import one slug and stamp the result. Idempotent: Board.from_obf upserts by
  # (user_id, obf_id), so re-running updates the same boards. Returns the root.
  #
  # Because Board.from_obf only ever UPSERTS (it never removes tiles/boards that
  # vanished from the OBF source — correct for user OBZ imports), the seeder adds
  # a destructive SYNC pass afterwards, scoped strictly to admin-owned set boards:
  # removed tiles and removed/renamed boards are pruned so a re-seed fully applies
  # content revisions (#277) and the one-time migration off the colliding
  # un-namespaced ids (#278) is automatic. User clones are deep copies and are
  # never touched.
  def seed_slug!(slug)
    result = ObzImporter.new(
      obz_bytes(slug),
      admin,
      board_group: nil, # root-board-only — no BoardGroup
      import_options: {
        include_images: true, # our own art; copyright gate is for third-party .obz
        license_acknowledged: true,
        acknowledged_by_user_id: admin.id,
        # #279: apply each button's authored part_of_speech (Fitzgerald-key
        # color) to the BoardImage. Seeder-only — user OBZ imports keep the
        # historical Board.from_obf behavior.
        apply_button_attributes: true,
      },
    ).import!

    root = result[:root_board]
    raise "Import produced no root board for #{slug.inspect}" unless root

    boards_by_obf_id = result[:boards]
    boards_by_obf_id.values.each do |board|
      # disable_scroll: the native board page (BoardNativeGridPage) reads
      # settings["disable_scroll"] and, when true, locks IonContent scrolling
      # and sizes rows so the whole authored grid (Core 60: 10×6,
      # Core 84: 12×7) renders on one page. clone_with_images dups settings,
      # so user clones inherit it.
      board.settings = (board.settings || {}).merge("disable_scroll" => true)
      board.update!(predefined: true, published: true)
    end
    Boards::RobustSets.mark_root!(root, slug)

    prune_removed_tiles!(slug, boards_by_obf_id)
    prune_removed_boards!(slug, boards_by_obf_id)
    dedupe_tiles!(boards_by_obf_id)
    repair_layout!(slug, boards_by_obf_id)
    unstack_layout!(boards_by_obf_id)

    # LAST, so it classifies the set that actually survived the prune passes.
    # A seeded set has no BoardGroup, so the classifier walks it from the root:
    # the root stays a main board, every page under it becomes a sub-board.
    # Without this the set's ~30 interior pages are all main boards, and since
    # the seeder marks them predefined + published they land in the public
    # gallery and in every user's board search.
    Boards::ImportedSetClassifier.new(root.reload).call

    root
  end

  # Re-pin every surviving tile to its AUTHORED grid cell, read straight from the
  # source OBF and matched by the stable obf_button_id stamped on the tile. Runs
  # LAST in the seed pass — after prune + dedupe — so it heals the layout
  # corruption a prior buggy re-seed could leave: when find_or_create_image_for_button
  # forked a duplicate tile, the upsert set the matched tile's coords but a
  # leftover copy kept stale coords, and dedupe could keep the wrong one — leaving
  # two tiles sharing one cell (e.g. core-84 "wait" on "again" at [10,5]) while
  # another cell sat empty. The board then renders with one tile hidden behind
  # another ("84 looks like 82"). Neither dedupe (different labels, not duplicates)
  # nor LayoutRepacker (the cell is in-grid, not overflow) catches that. Authored
  # buttons are all 1×1 grid cells, so we pin w/h to 1 — matching the upsert.
  # Admin-owned set boards only; user clones are healed by board_builder:repair_grid.
  def repair_layout!(slug, boards_by_obf_id)
    coords_by_obf_id  = source_coords_by_obf_id(slug)
    buttons_by_obf_id = source_buttons_by_obf_id(slug)

    boards_by_obf_id.each do |obf_id, board|
      coords = coords_by_obf_id[obf_id]
      next if coords.blank?

      tiles = board.board_images.to_a
      changed = false

      # Pass 1 — the exact match. A tile stamped with its authored button id is
      # pinned to that button's cell, whatever it drifted to.
      tiles.each do |bi|
        button_id = tile_button_id(bi)
        next if button_id.blank?

        changed = true if pin_to_cell!(bi, coords[button_id])
      end

      # Pass 2 — the un-stamped tail. A tile seeded before button ids were
      # stamped (or one a buggy re-seed forked) carries none, so pass 1 can
      # never move it: core-84's `all done` sat on `again`'s cell through every
      # re-seed while its own cell stayed empty, which is what let a build spend
      # a phantom open cell (Board#open_grid_cells counts DISTINCT cells).
      # Match it to the ONE authored button with its label that no stamped tile
      # already claims, then stamp the id so this is a pass-1 tile forever after.
      # An ambiguous label (core-84 authors the word `play` AND the folder
      # `Play`) is left to unstack_layout!.
      claimed = tiles.filter_map { |bi| tile_button_id(bi) }.to_set
      labels  = buttons_by_obf_id[obf_id] || {}

      tiles.each do |bi|
        next if tile_button_id(bi).present?

        button_id = sole_unclaimed_button_id(labels, claimed, bi)
        next if button_id.nil?

        # No authored cell for that button (it isn't in the grid order): there
        # is nothing to pin, and stamping the id without pinning would claim it
        # for a tile this pass didn't actually fix.
        cell = coords[button_id]
        next if cell.nil?

        claimed << button_id
        bi.data = (bi.data || {}).merge("obf_button_id" => button_id)
        pin_to_cell!(bi, cell, force_save: true)
        changed = true
      end

      board.update_board_layout("lg") if changed
    end
  end

  # The authored button id stamped on a tile, or nil.
  def tile_button_id(board_image)
    return nil unless board_image.data.is_a?(Hash)

    board_image.data["obf_button_id"].presence&.to_s
  end

  # The id of the single authored button carrying this tile's label that no
  # other tile has claimed. nil when the label is absent, ambiguous, or taken —
  # every one of those is a case where guessing would move the wrong tile.
  def sole_unclaimed_button_id(labels_by_button_id, claimed, board_image)
    label = (board_image.label.presence || board_image.image&.label).to_s.strip.downcase
    return nil if label.blank?

    matches = labels_by_button_id.filter_map do |button_id, authored|
      button_id if !claimed.include?(button_id) && authored.to_s.strip.downcase == label
    end
    matches.size == 1 ? matches.first : nil
  end

  # Pin one tile to its authored 1x1 cell across every persisted screen size.
  # Returns true when it wrote. Authored buttons are all 1x1, matching the
  # upsert. `force_save:` writes even when the coords already match, so a
  # freshly-stamped obf_button_id is persisted alongside them.
  def pin_to_cell!(board_image, cell, force_save: false)
    return false if cell.nil?

    x, y = cell
    if already_at?(board_image, x, y)
      return false unless force_save

      board_image.save!
      return true
    end

    layout = { "x" => x, "y" => y, "w" => 1, "h" => 1, "i" => board_image.id.to_s }
    board_image.layout ||= {}
    %w[lg md sm xs xxs].each { |screen| board_image.layout[screen] = layout }
    board_image.save!
    true
  end

  # Last resort after repair_layout!: pull any tile still sharing a cell (or
  # sitting off-grid) into a free one. A set must never SHIP that state — every
  # user clone inherits the layout verbatim, so one stacked seed cell becomes a
  # stacked cell in every set ever built from it, and because
  # Board#open_grid_cells counts DISTINCT cells it also makes a full grid report
  # a free cell the build then spends.
  #
  # `unstack!`, not `repack!`: an authored grid is exactly as many cells as
  # tiles, so the displaced tile belongs in the gap its twin left, not shelf-
  # packed onto a new row (which would defeat the set's `disable_scroll`).
  # Idempotent: returns 0 and writes nothing on a clean set.
  def unstack_layout!(boards_by_obf_id)
    boards_by_obf_id.each_value do |board|
      moved = Boards::LayoutRepacker.unstack!(board.reload)
      next if moved.zero?

      Rails.logger.info "[VocabSets] un-stacked #{moved} displaced tile(s) on board #{board.id} (#{board.name})"
    end
  end

  # True when the tile already sits at [x, y] across the persisted screens, so a
  # re-seed of a clean set is a no-op (no needless writes / preview churn).
  def already_at?(board_image, x, y)
    layout = board_image.layout
    return false unless layout.is_a?(Hash)

    %w[lg md sm].all? do |screen|
      cell = layout[screen]
      cell.is_a?(Hash) && cell["x"] == x && cell["y"] == y
    end
  end

  # { obf_id => { button_id => [x, y] } } parsed straight from each authored OBF
  # in the slug's manifest — the canonical grid placement repair_layout! pins to.
  def source_coords_by_obf_id(slug)
    dir = SETS_DIR.join(slug)
    manifest = JSON.parse(File.read(dir.join("manifest.json")))
    paths = (manifest.dig("paths", "boards") || {}).values.uniq

    paths.each_with_object({}) do |rel, acc|
      file = dir.join(rel)
      next unless File.file?(file)

      obf = JSON.parse(File.read(file))
      order = obf.dig("grid", "order")
      next unless order.is_a?(Array)

      coords = {}
      order.each_with_index do |row, y|
        Array(row).each_with_index do |button_id, x|
          next if button_id.to_s.strip.empty?

          coords[button_id.to_s] = [x, y]
        end
      end
      acc[obf["id"].to_s] = coords
    end
  end

  # Collapse duplicate tiles a prior buggy re-seed may have appended. The label
  # is still authored, so prune_removed_tiles! keeps BOTH copies — this removes
  # the extra. Admin-owned set boards only; user clones are separate rows healed
  # by rake board_builder:dedupe_seed_tiles. Idempotent: a no-op once clean.
  def dedupe_tiles!(boards_by_obf_id)
    boards_by_obf_id.each_value do |board|
      Boards::TileDeduper.collapse_duplicates!(board)
    end
  end

  # Map of obf_id => [button labels] parsed straight from the authored source
  # for a slug. Used to decide which tiles on a seeded board are still authored.
  def source_labels_by_obf_id(slug)
    dir = SETS_DIR.join(slug)
    manifest = JSON.parse(File.read(dir.join("manifest.json")))
    paths = (manifest.dig("paths", "boards") || {}).values.uniq

    paths.each_with_object({}) do |rel, acc|
      file = dir.join(rel)
      next unless File.file?(file)

      obf = JSON.parse(File.read(file))
      acc[obf["id"].to_s] = Array(obf["buttons"]).map { |b| b["label"] }.compact
    end
  end

  # Destroy board_images on each seeded board whose authored button is gone from
  # the source OBF (e.g. #276 removed please/thank you/and from the homes, "more"
  # from fringe pages, and the self-link folder tiles).
  #
  # A tile stamped with an obf_button_id is matched by THAT id — the same stable
  # key repair_layout! pins coordinates with, and the only one that can tell two
  # buttons sharing a label apart. Label matching alone is case-insensitive, so a
  # removed folder tile survived whenever the board also authored a word of the
  # same name: dropping the "Home" folder from places.obf left the tile in place
  # (the page still authors the WORD "home"), and repair_layout! then couldn't
  # move it — its button id is gone from the source — so it kept its old cell and
  # collided with whatever now sits there. Tiles seeded before button ids were
  # stamped carry none, and still fall back to the label check.
  #
  # Admin-owned set boards only; user clones are separate rows.
  def prune_removed_tiles!(slug, boards_by_obf_id)
    labels_by_id = source_labels_by_obf_id(slug)
    button_ids_by_id = source_button_ids_by_obf_id(slug)

    boards_by_obf_id.each do |obf_id, board|
      next unless labels_by_id.key?(obf_id) # never blank-prune a board we can't source

      keep = labels_by_id[obf_id].map { |l| l.to_s.strip.downcase }
      keep_button_ids = button_ids_by_id[obf_id] || []
      board.board_images.includes(:image).find_each do |bi|
        button_id = bi.data.is_a?(Hash) ? bi.data["obf_button_id"].presence : nil
        if button_id
          bi.destroy unless keep_button_ids.include?(button_id.to_s)
          next
        end

        label = (bi.image&.label || bi.label).to_s.strip.downcase
        bi.destroy unless keep.include?(label)
      end
    end
  end

  # { obf_id => [button ids] } parsed straight from the authored source for a
  # slug — the stable ids prune_removed_tiles! / repair_layout! match tiles on.
  def source_button_ids_by_obf_id(slug)
    dir = SETS_DIR.join(slug)
    manifest = JSON.parse(File.read(dir.join("manifest.json")))
    paths = (manifest.dig("paths", "boards") || {}).values.uniq

    paths.each_with_object({}) do |rel, acc|
      file = dir.join(rel)
      next unless File.file?(file)

      obf = JSON.parse(File.read(file))
      acc[obf["id"].to_s] = Array(obf["buttons"]).filter_map { |b| b["id"].presence&.to_s }
    end
  end

  # { obf_id => { button_id => label } } from the authored source — what
  # repair_layout!'s second pass matches an un-stamped tile against.
  def source_buttons_by_obf_id(slug)
    each_source_obf(slug).each_with_object({}) do |obf, acc|
      acc[obf["id"].to_s] = Array(obf["buttons"]).each_with_object({}) do |button, index|
        id = button["id"].presence&.to_s
        next if id.nil?

        index[id] = button["label"].to_s
      end
    end
  end

  # Every authored OBF in a slug's manifest, parsed. The three
  # source_*_by_obf_id readers above each re-read and re-parse the same files;
  # new readers go through this.
  def each_source_obf(slug)
    dir = SETS_DIR.join(slug)
    manifest = JSON.parse(File.read(dir.join("manifest.json")))
    paths = (manifest.dig("paths", "boards") || {}).values.uniq

    paths.filter_map do |rel|
      file = dir.join(rel)
      next unless File.file?(file)

      JSON.parse(File.read(file))
    end
  end

  # Destroy admin-owned boards that belonged to this set but are no longer in the
  # manifest: namespaced ids dropped from the manifest, plus the bare
  # (un-namespaced) ids from the pre-namespacing collision era (#278) and any
  # fully-removed boards (LEGACY_REMOVED_OBF_IDS, e.g. keyboard from #276). This
  # makes the migration off the shared fringe boards self-healing on one re-seed.
  # Strictly scoped to User::DEFAULT_ADMIN_ID; destroying these nulls inbound
  # predictive_board_id pointers (Board has_many predictive_board_images,
  # dependent: :nullify), so nothing dangles. User clones never point at these.
  def prune_removed_boards!(slug, boards_by_obf_id)
    current_ids = boards_by_obf_id.keys

    # Namespaced orphans: in this set's namespace but no longer imported.
    Board.where(user_id: admin.id)
      .where("obf_id LIKE ?", "#{slug}:%")
      .where.not(obf_id: current_ids)
      .destroy_all

    # Legacy bare ids: the pre-namespacing version of each current board, plus
    # boards removed from the manifest outright.
    legacy_ids = (current_ids.map { |id| id.split(":", 2).last } + LEGACY_REMOVED_OBF_IDS).uniq
    Board.where(user_id: admin.id, obf_id: legacy_ids).destroy_all
  end
end
