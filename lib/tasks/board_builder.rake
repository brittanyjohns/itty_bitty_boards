namespace :board_builder do
  # Backfill for the Board Builder art-resolution fix: before this, only the
  # root board of a built set ran the blank->art tile upgrade. The fringe/
  # sub-boards (and standalone prebuilt fringe pages) were cloned through
  # Board#clone_with_images, which has no upgrade, so their authored tiles
  # rendered blank wherever they pointed at an art-less library image.
  #
  # This re-runs Boards::ImageResolver.upgrade_board_tiles! across every already-
  # built set (root + children, marked settings["builder_root"]/["builder_child"])
  # so existing sets pick up the curated "default" image (admin image with the
  # most docs) for each label — exactly what new builds now do.
  #
  # Read-only by default (reports candidates). Apply with DRY_RUN=false.
  # Optionally scope to one owner with USER_ID=N:
  #   rake board_builder:upgrade_tile_images                      # preview all
  #   DRY_RUN=false rake board_builder:upgrade_tile_images        # apply all
  #   DRY_RUN=false USER_ID=740 rake board_builder:upgrade_tile_images
  desc "Upgrade blank Board Builder tiles to curated art (DRY_RUN=false to apply; USER_ID=N to scope)"
  task upgrade_tile_images: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    scope = Board.where("(settings ->> 'builder_root') = 'true' OR (settings ->> 'builder_child') = 'true'")
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    boards_touched = 0
    tiles_upgraded = 0

    scope.find_each do |board|
      owner = board.user
      next unless owner

      candidates = blank_tile_candidates(board, owner)
      next if candidates.zero?

      boards_touched += 1
      label = board.settings&.dig("builder_root") ? "root" : "child"
      puts "#{dry_run ? '[DRY RUN] ' : ''}board ##{board.id} #{board.name.inspect} (#{label}, owner #{owner.id}): #{candidates} tile(s) to upgrade"

      unless dry_run
        Boards::ImageResolver.upgrade_board_tiles!(board, owner: owner)
        tiles_upgraded += candidates
      end
    end

    if dry_run
      puts "Dry run only — #{boards_touched} board(s) with upgradeable tiles. Re-run with DRY_RUN=false to apply."
    else
      puts "Upgraded ~#{tiles_upgraded} tile(s) across #{boards_touched} board(s)."
    end
  end

  # Remediation for the "extra all done" duplicate-tile bug. A re-seed of the
  # Core 60/84 builder source appended a second word tile for a label whose
  # button->image resolution drifted (see Boards::TileDeduper / Board
  # .upsert_board_image), and SeededSetCloner copied it into every set built
  # since. This collapses those duplicates on:
  #   - the robust seed SOURCE boards (root + descendants), and
  #   - every already-built user set (settings builder_root / builder_child).
  # Keeps the authored-position tile; removes the appended copy. A word tile and
  # its same-named category folder ("play" vs "Play") are NOT merged.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with USER_ID=N:
  #   rake board_builder:dedupe_seed_tiles                  # preview all
  #   DRY_RUN=false rake board_builder:dedupe_seed_tiles    # apply all
  #   DRY_RUN=false USER_ID=740 rake board_builder:dedupe_seed_tiles
  desc "Collapse duplicate Board Builder tiles on seeds + built sets (DRY_RUN=false to apply; USER_ID=N to scope)"
  task dedupe_seed_tiles: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    boards = dedupe_target_boards(ENV["USER_ID"])
    boards_touched = 0
    tiles_removed = 0

    boards.each do |board|
      groups = Boards::TileDeduper.duplicate_groups(board)
      next if groups.empty?

      boards_touched += 1
      removed_here = groups.sum { |_key, tiles| tiles.size - 1 }
      tiles_removed += removed_here

      detail = groups.map { |(label, _folder), tiles| "#{label.inspect} x#{tiles.size} (keep pos #{tiles.first.position})" }.join(", ")
      kind = board.settings&.dig("board_builder_robust_slug") ? "seed" : (board.settings&.dig("builder_root") ? "root" : "child")
      puts "#{dry_run ? '[DRY RUN] ' : ''}board ##{board.id} #{board.name.inspect} (#{kind}, owner #{board.user_id}): #{detail}"

      Boards::TileDeduper.collapse_duplicates!(board) unless dry_run
    end

    if dry_run
      puts "Dry run only — #{boards_touched} board(s), #{tiles_removed} duplicate tile(s) to remove. Re-run with DRY_RUN=false to apply."
    else
      puts "Removed #{tiles_removed} duplicate tile(s) across #{boards_touched} board(s)."
    end
  end

  # Full grid repair for the "Speak view looks different" bug: collapse duplicate
  # tiles (keeping the IN-GRID copy) AND repack any remaining out-of-grid tiles
  # back inside the configured columns, across the robust seed sources and every
  # built user set. This is the complete fix — dedupe_seed_tiles alone leaves the
  # off-grid folder duplicates in place when their lower-position copy is the
  # off-grid one. Regenerates the board preview for any board it changes.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with USER_ID=N:
  #   rake board_builder:repair_grid                  # preview all
  #   DRY_RUN=false rake board_builder:repair_grid    # apply all
  #   DRY_RUN=false USER_ID=740 rake board_builder:repair_grid
  desc "Dedupe + repack out-of-grid Board Builder tiles (DRY_RUN=false to apply; USER_ID=N to scope)"
  task repair_grid: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    boards = dedupe_target_boards(ENV["USER_ID"])
    boards_touched = 0
    tiles_removed = 0
    tiles_moved = 0

    boards.each do |board|
      # In a dry run nothing is destroyed, so tell the repacker which off-grid
      # duplicates the dedupe pass WOULD remove first — otherwise they'd be
      # double-counted as overflow tiles needing a repack.
      removable = dry_run ? Boards::TileDeduper.removable_tile_ids(board) : []
      removed = Boards::TileDeduper.collapse_duplicates!(board, dry_run: dry_run)
      board.board_images.reset unless dry_run
      moved = Boards::LayoutRepacker.repack!(board, dry_run: dry_run, ignore_ids: removable)
      next if removed.zero? && moved.zero?

      boards_touched += 1
      tiles_removed += removed
      tiles_moved += moved
      kind = board.settings&.dig("board_builder_robust_slug") ? "seed" : (board.settings&.dig("builder_root") ? "root" : "child")
      puts "#{dry_run ? '[DRY RUN] ' : ''}board ##{board.id} #{board.name.inspect} (#{kind}, owner #{board.user_id}): #{removed} duplicate(s) removed, #{moved} tile(s) repacked"

      board.run_generate_preview_job unless dry_run
    end

    if dry_run
      puts "Dry run only — #{boards_touched} board(s): #{tiles_removed} duplicate(s) to remove, #{tiles_moved} tile(s) to repack. Re-run with DRY_RUN=false to apply."
    else
      puts "Repaired #{boards_touched} board(s): removed #{tiles_removed} duplicate(s), repacked #{tiles_moved} tile(s)."
    end
  end

  # Boards to scan: robust seed SOURCE boards (root + linked descendants, the
  # template clones copy from) plus every built user set. USER_ID scopes to one
  # owner (seed sources are admin-owned, so a non-admin USER_ID yields built
  # sets only).
  def dedupe_target_boards(user_id = nil)
    seed_roots = Board.where("(settings ->> 'board_builder_robust_slug') IS NOT NULL")
    ids = seed_roots.pluck(:id).to_set
    seed_roots.find_each { |root| collect_set_descendant_ids(root, ids) }

    built = Board.where("(settings ->> 'builder_root') = 'true' OR (settings ->> 'builder_child') = 'true'")
    ids.merge(built.pluck(:id))

    scope = Board.where(id: ids.to_a)
    scope = scope.where(user_id: user_id) if user_id.present?
    scope
  end

  # Walk predictive_board_id links from a seed root, bounded to the cloner's
  # MAX_DEPTH (root + 2 levels), accumulating board ids.
  def collect_set_descendant_ids(board, acc, depth = 2)
    return if depth.negative? || board.nil?

    board.board_images.where.not(predictive_board_id: nil).pluck(:predictive_board_id).uniq.each do |child_id|
      next if acc.include?(child_id)

      acc << child_id
      collect_set_descendant_ids(Board.find_by(id: child_id), acc, depth - 1)
    end
  end

  # Count tiles on `board` that are currently blank (art-less) but for which a
  # curated art-bearing image exists under the same label — i.e. the tiles
  # upgrade_board_tiles! would actually re-point. Read-only.
  def blank_tile_candidates(board, owner)
    board.board_images.includes(:image).count do |bi|
      image = bi.image
      next false if Boards::ImageResolver.art?(image)

      label = bi.label.presence || image&.label
      next false if label.blank?

      arted = Boards::ImageResolver.best_arted_for(label, owner)
      !arted.nil? && arted.id != image&.id
    end
  end
end
