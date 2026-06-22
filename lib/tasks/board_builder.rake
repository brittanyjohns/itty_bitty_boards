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
