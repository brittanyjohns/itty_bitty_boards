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

  # Backfill for the Board Builder scope/classification fix. Sets built before
  # that change have:
  #   - roots that never registered as in_use (the ChildBoard attaches the root
  #     directly, and the old Board#check_in_use only counted clone sources), so
  #     they never surfaced under the "in use" scope, AND
  #   - sub-boards (builder_child) that leaked into the `main_boards` scope
  #     (their sub_board column was never set true), AND
  #   - sub-boards left FROZEN (settings["freeze_board"] = true), so a word tap
  #     never returned to home. Builder pages behave like any other board now.
  #
  # This re-saves each built set so Board#check_in_use / #check_is_sub_board
  # recompute against the now-complete relations, and clears freeze_board from
  # every child page — matching what BuildBoardSetJob#classify_sub_boards! does
  # at build time. Only ever unfreezes builder_child pages, so a board the user
  # froze themselves elsewhere is untouched.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with USER_ID=N:
  #   rake board_builder:reclassify_builder_sets               # preview all
  #   DRY_RUN=false rake board_builder:reclassify_builder_sets  # apply all
  #   DRY_RUN=false USER_ID=740 rake board_builder:reclassify_builder_sets
  desc "Reclassify built Board Builder sets: root in_use, children sub_board + unfrozen (DRY_RUN=false to apply; USER_ID=N to scope)"
  task reclassify_builder_sets: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    roots = Board.where("(settings ->> 'builder_root') = 'true'")
    roots = roots.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    sets_touched = 0
    children_unfrozen = 0

    roots.find_each do |root|
      child_ids = builder_set_child_ids(root)
      sets_touched += 1
      puts "#{dry_run ? '[DRY RUN] ' : ''}set ##{root.id} #{root.name.inspect} (owner #{root.user_id}): root in_use, #{child_ids.size} child page(s) sub_board + unfrozen"

      next if dry_run

      # Re-save the root so check_in_use picks up its direct ChildBoard.
      root.save!
      Board.where(id: child_ids).find_each do |child|
        was_frozen = child.settings&.dig("freeze_board") == true
        child.settings = (child.settings || {}).except("freeze_board")
        child.save! # recomputes check_is_sub_board => sub_board: true
        children_unfrozen += 1 if was_frozen
      end
    end

    if dry_run
      puts "Dry run only — #{sets_touched} built set(s) to reclassify. Re-run with DRY_RUN=false to apply."
    else
      puts "Reclassified #{sets_touched} set(s); unfroze #{children_unfrozen} child page(s)."
    end
  end

  # Backfill for the nav-row sync. Sets built before it landed carry the old
  # per-page nav row (a `Home` tile plus categories shifted left to fill the
  # gap), and built sets are clones — re-seeding the authored templates never
  # reaches them. This re-projects each root's nav row onto every page of its
  # set: legacy nav tiles are removed, other content in a nav cell is relocated
  # rather than deleted.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with USER_ID=N:
  #   rake board_builder:sync_nav_rows                       # preview all
  #   DRY_RUN=false rake board_builder:sync_nav_rows         # apply all
  #   DRY_RUN=false USER_ID=740 rake board_builder:sync_nav_rows
  desc "Re-project the nav row onto every page of each built set (DRY_RUN=false to apply; USER_ID=N to scope)"
  task sync_nav_rows: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    roots = Board.where("(settings ->> 'builder_root') = 'true'")
    roots = roots.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    sets = 0
    tiles = 0
    folders = 0
    words = 0
    deduped = 0

    roots.find_each do |root|
      result = Boards::NavRowSync.call(root, dry_run: dry_run)
      next if result.boards_synced.zero?

      sets += 1
      tiles += result.tiles_written
      folders += result.folders_deleted
      words += result.words_relocated
      deduped += result.words_deduped

      puts "#{dry_run ? '[DRY RUN] ' : ''}set ##{root.id} #{root.name.inspect} (owner #{root.user_id}): " \
           "#{result.boards_synced} page(s), #{result.tiles_written} nav tile(s), " \
           "#{result.folders_deleted} legacy nav tile(s) removed, #{result.words_relocated} tile(s) relocated, " \
           "#{result.words_deduped} duplicate nav word(s) removed"

      next if dry_run

      # Only the pages the sync touched need a fresh preview. Board#generate_previews
      # raises an ArgumentError about url_options outside a request in dev/test —
      # the same non-fatal case BuildBoardSetJob#generate_preview! rescues.
      Boards::PredictiveLinkSet
        .collect(root, max_depth: Boards::NavRowSync::MAX_DEPTH,
                       exclude: ->(b) { b.user_id != root.user_id })
        .each do |board|
          board.generate_previews
        rescue ArgumentError => e
          raise unless e.message.include?("url_options")
        end
    rescue => e
      puts "  !! set ##{root.id} failed: #{e.message}"
    end

    if dry_run
      puts "Dry run only — #{sets} built set(s) to sync (#{tiles} nav tile(s), #{folders} legacy nav tile(s), #{words} relocation(s)). Re-run with DRY_RUN=false to apply."
    else
      puts "Synced #{sets} set(s): #{tiles} nav tile(s) written, #{folders} legacy nav tile(s) removed, " \
           "#{words} tile(s) relocated, #{deduped} duplicate nav word(s) removed."
    end
  end

  # Repairs the "stray core page" damage in already-built sets.
  #
  # A folder tile pointing at a board that is itself the TOP of a set (a
  # robust-set root, or another builder set's root/child) used to pull that
  # whole board into the clone as an extra PAGE. The page is a second full core
  # board, so no nav cell carries its name, so Boards::NavRowSync gave it an
  # explicit way home labelled with the core set's own name — the stray
  # "Core 84" tile. Where the page had also inherited a stacked cell from the
  # seed, that anchor landed in the phantom hole the stack left, and the grid
  # spilled onto an extra row.
  #
  # Three passes, in order:
  #   1. destroy the minted way-home tile on a stray core page (a `nav_tile`
  #      whose label is the page's own name — never a real nav cell, which is
  #      always labelled for a SIBLING page);
  #   2. un-stack every board in the set (Boards::LayoutRepacker);
  #   3. restore `disable_scroll` on a stray page that is back to its seed's
  #      authored row count. Deliberately only there: the set ROOT does not
  #      record which seed it came from (clone_into_adopted_root strips the
  #      markers), so "is this grid still its authored size" is unanswerable for
  #      it and guessing could lock a legitimately grown board to one page.
  #
  # DESTROY_STRAY=true additionally destroys a stray page that is ORPHANED —
  # nothing in the set links to it any more, so removing it costs the set
  # nothing. Opt-in, and never applied to a page that is still reachable.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with USER_ID=N:
  #   rake board_builder:repair_stray_core_pages                     # preview all
  #   DRY_RUN=false rake board_builder:repair_stray_core_pages       # apply
  #   DRY_RUN=false DESTROY_STRAY=true rake board_builder:repair_stray_core_pages
  desc "Remove stray core pages + their minted home tiles from built sets (DRY_RUN=false to apply; USER_ID=N to scope; DESTROY_STRAY=true to delete orphaned pages)"
  task repair_stray_core_pages: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    destroy_stray = ENV["DESTROY_STRAY"] == "true"

    roots = Board.where("(settings ->> 'builder_root') = 'true'")
    roots = roots.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    sets = 0
    stray_pages = 0
    orphans_destroyed = 0
    tiles_removed = 0
    tiles_moved = 0
    scroll_restored = 0

    roots.find_each do |root|
      reachable = Boards::PredictiveLinkSet
        .collect(root, max_depth: Boards::NavRowSync::MAX_DEPTH,
                       exclude: ->(b) { b.user_id != root.user_id })
      reachable_ids = reachable.map(&:id).to_set

      # Group membership too: a stray page can be orphaned (nothing links to it)
      # and still be a member, which is exactly the state worth reporting.
      members = root.builder_board_group&.boards&.where(user_id: root.user_id)&.to_a || []
      boards = (reachable + members).uniq(&:id)

      lines = []

      boards.each do |board|
        next if board.id == root.id

        if stray_core_page?(board)
          stray_pages += 1
          orphaned = !reachable_ids.include?(board.id)
          lines << "  stray core page ##{board.id} #{board.name.inspect}" \
                   "#{orphaned ? ' (ORPHANED — nothing links to it)' : ''}"

          removed = destroy_minted_home_tiles!(board, dry_run: dry_run)
          tiles_removed += removed
          lines << "    #{removed} minted way-home tile(s) removed" if removed.positive?

          if destroy_stray && orphaned && board.marketplace_protected?
            # Board#block_marketplace_protected_destroy would abort this anyway;
            # say so rather than surfacing a callback exception. A page whose
            # content was sold as a PDF keeps its /pb/<slug> forever.
            lines << "    NOT destroyed — a marketplace listing depends on it"
          elsif destroy_stray && orphaned
            orphans_destroyed += 1
            lines << "    page destroyed"
            board.destroy! unless dry_run
            next
          end

          scroll_restored += 1 if restore_seed_disable_scroll!(board, dry_run: dry_run)
        end

        moved = Boards::LayoutRepacker.unstack!(board, dry_run: dry_run)
        next if moved.zero?

        tiles_moved += moved
        lines << "  board ##{board.id} #{board.name.inspect}: #{moved} stacked/off-grid tile(s) repacked"
      end

      next if lines.empty?

      sets += 1
      puts "#{dry_run ? '[DRY RUN] ' : ''}set ##{root.id} #{root.name.inspect} (owner #{root.user_id}):"
      puts lines
    rescue => e
      puts "  !! set ##{root.id} failed: #{e.message}"
    end

    summary = "#{sets} set(s): #{stray_pages} stray core page(s), #{tiles_removed} minted tile(s), " \
              "#{tiles_moved} tile(s) repacked, #{scroll_restored} page(s) re-locked to one screen, " \
              "#{orphans_destroyed} orphan page(s) destroyed"
    if dry_run
      puts "Dry run only — #{summary}. Re-run with DRY_RUN=false to apply."
    else
      puts "Repaired #{summary}."
    end
  end

  desc "Strip robust-set markers from boards that aren't the real Core 60/84 seed (DRY_RUN=false to apply)"
  task unmark_stray_vocab_roots: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    # Deliberately UNSCOPED: Boards::RobustSets.all_roots is now narrowed to the
    # seeder's own boards, which is the whole point — the strays this task
    # cleans up are precisely the rows that scope no longer sees.
    marked = Board
      .where("COALESCE((boards.settings->>'#{Boards::RobustSets::ROOT_MARKER}')::boolean, false)")
      .order(:id)
      .to_a

    if marked.empty?
      puts "No boards carry #{Boards::RobustSets::ROOT_MARKER}. Nothing to do."
      next
    end

    seed_ids = marked.select { |b| true_vocab_seed?(b) }
                     .group_by { |b| Boards::RobustSets.slug_for(b) }
                     .transform_values { |boards| boards.min_by(&:id).id }
                     .values
                     .to_set

    strays = marked.reject { |b| seed_ids.include?(b.id) }

    puts "#{marked.size} marked board(s): #{seed_ids.size} real seed(s), #{strays.size} stray(s)."
    marked.each do |board|
      role = seed_ids.include?(board.id) ? "SEED " : "STRAY"
      puts "  #{role} ##{board.id} #{board.name.inspect} " \
           "slug=#{Boards::RobustSets.slug_for(board).inspect} user=#{board.user_id} " \
           "predefined=#{board.predefined} published=#{board.published} obf_id=#{board.obf_id.inspect}"
    end

    if strays.empty?
      puts "Nothing to unmark."
      next
    end

    # Report-only, twice over. Renaming a user's board is not this task's call
    # (a board name is user-visible content), and unpublishing an admin board
    # isn't either — but both consequences are worth naming out loud.
    report_sets_named_after!(strays)
    report_newly_catalogued!(strays)

    unless dry_run
      strays.each do |board|
        settings = board.settings || {}
        settings.delete(Boards::RobustSets::ROOT_MARKER)
        settings.delete(Boards::RobustSets::SLUG_MARKER)
        board.update_columns(settings: settings)
      end
    end

    if dry_run
      puts "Dry run only — would unmark #{strays.size} stray root(s). Re-run with DRY_RUN=false to apply."
    else
      puts "Unmarked #{strays.size} stray root(s). No board was renamed, unpublished, or destroyed."
    end
  end

  # The board a re-seed would produce for this slug: owned by the seeder and
  # flagged predefined. `Board#clone_with_images` sets predefined = false, so a
  # clone can never satisfy this however its settings got stamped.
  def true_vocab_seed?(board)
    board.user_id == User::DEFAULT_ADMIN_ID &&
      board.predefined? &&
      Boards::RobustSets.slug_for(board).present?
  end

  # Built sets whose root (or BoardGroup) took its name from a stray. Reported,
  # never renamed — the fix stops NEW builds inheriting the name; renaming an
  # existing board is the owner's call.
  def report_sets_named_after!(strays)
    names = strays.map { |b| b.name.to_s.strip }.reject(&:blank?).uniq
    return if names.empty?

    roots = Board.where("(settings ->> 'builder_root') = 'true'").where(name: names)
    groups = BoardGroup.where(builder: true, name: names)
    return if roots.empty? && groups.empty?

    puts "Built sets named after a stray (NOT renamed — rename by hand if you want to):"
    roots.each { |b| puts "  board ##{b.id} #{b.name.inspect} user=#{b.user_id}" }
    groups.each { |g| puts "  board set ##{g.id} #{g.name.inspect} user=#{g.user_id}" }
  end

  # Board.not_builder_seed excludes marked boards from admin_owned_boards, so
  # unmarking a published admin board admits it to the admin printables
  # dashboard. Say so rather than quietly changing what that list shows.
  def report_newly_catalogued!(strays)
    surfacing = strays.select { |b| b.published? && b.user_id == User::DEFAULT_ADMIN_ID }
    return if surfacing.empty?

    puts "Unmarking these will admit them to Board.admin_owned_boards (admin printables dashboard):"
    surfacing.each { |b| puts "  ##{b.id} #{b.name.inspect}" }
  end

  # A page in a built set that is really the top of a robust vocabulary set —
  # it still carries the seed's catalogue marker. An authored fringe page never
  # does.
  def stray_core_page?(board)
    settings = board.settings
    return false unless settings.is_a?(Hash)

    settings[Boards::RobustSets::ROOT_MARKER].present? &&
      settings["builder_root"].blank?
  end

  # The way-home tile Boards::NavRowSync mints for a page with no self tile:
  # flagged `nav_tile`, labelled with the page's OWN name. A genuine nav cell is
  # always labelled for a sibling page, so this can't catch one.
  def destroy_minted_home_tiles!(board, dry_run:)
    name = board.name.to_s.strip
    return 0 if name.blank?

    targets = board.board_images.select do |bi|
      data = bi.data
      data.is_a?(Hash) && data[Boards::NavRowSync::NAV_TILE_KEY] == true &&
        bi.label.to_s.strip.casecmp?(name)
    end
    return targets.size if dry_run

    targets.each(&:destroy!)
    board.board_images.reset
    targets.size
  end

  # Re-lock a stray core page to one screen once it is back to the authored row
  # count of the seed it was copied from. Only answerable for these pages —
  # they still carry `board_builder_robust_slug`, so the seeded root is a lookup
  # away.
  def restore_seed_disable_scroll!(board, dry_run:)
    settings = board.settings || {}
    return false if settings["disable_scroll"] == true

    seed = Boards::RobustSets.find_root(settings[Boards::RobustSets::SLUG_MARKER])
    return false if seed.nil?
    return false unless board.reload.large_screen_rows == seed.large_screen_rows

    return true if dry_run

    board.update!(settings: settings.merge("disable_scroll" => true))
    true
  end

  # The builder_child boards under a built root: BFS predictive_board_id links
  # (bounded to the cloner's MAX_DEPTH), scoped to the owner so a tile pointing at
  # a shared/admin board can't pull it in. Excludes the root itself.
  def builder_set_child_ids(root)
    acc = Set.new
    collect_set_descendant_ids(root, acc)
    Board.where(id: acc.to_a, user_id: root.user_id).pluck(:id)
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
