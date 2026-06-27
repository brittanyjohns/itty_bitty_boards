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
    coords_by_obf_id = source_coords_by_obf_id(slug)

    boards_by_obf_id.each do |obf_id, board|
      coords = coords_by_obf_id[obf_id]
      next if coords.blank?

      changed = false
      board.board_images.find_each do |bi|
        button_id = bi.data.is_a?(Hash) ? bi.data["obf_button_id"] : nil
        next if button_id.blank?

        cell = coords[button_id.to_s]
        next if cell.nil?

        x, y = cell
        next if already_at?(bi, x, y)

        layout = { "x" => x, "y" => y, "w" => 1, "h" => 1, "i" => bi.id.to_s }
        bi.layout ||= {}
        %w[lg md sm xs xxs].each { |screen| bi.layout[screen] = layout }
        bi.save!
        changed = true
      end

      board.update_board_layout("lg") if changed
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

  # Destroy board_images on each seeded board whose label is no longer present in
  # the source OBF's buttons (e.g. #276 removed please/thank you/and from the
  # homes, "more" from fringe pages, and the self-link folder tiles). Matching is
  # by image label, case-insensitively — the same value Board.from_obf resolves a
  # button to. Admin-owned set boards only; user clones are separate rows.
  def prune_removed_tiles!(slug, boards_by_obf_id)
    labels_by_id = source_labels_by_obf_id(slug)

    boards_by_obf_id.each do |obf_id, board|
      next unless labels_by_id.key?(obf_id) # never blank-prune a board we can't source

      keep = labels_by_id[obf_id].map { |l| l.to_s.strip.downcase }
      board.board_images.includes(:image).find_each do |bi|
        label = (bi.image&.label || bi.label).to_s.strip.downcase
        bi.destroy unless keep.include?(label)
      end
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
