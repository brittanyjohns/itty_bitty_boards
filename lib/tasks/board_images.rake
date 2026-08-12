namespace :board_images do
  # Backfill for the back-tile fix: a tile that takes you BACK to a page you
  # came from is stored as an ordinary folder tile, so a walk over folder links
  # climbs UP out of the page it started on. That is what made deleting a child
  # page offer to delete its own set's home board.
  #
  # Boards::BackTileStamper marks those tiles with data["back_tile"] = true,
  # reading direction off Boards::SetDepths — anything that doesn't get you
  # further from the home board is a way back, not a descent. New sets get this
  # inline at import / group creation; this catches everything already in the
  # database.
  #
  # Only boards that belong to a BoardGroup with a root board can be measured;
  # a board in no set has no home to measure from and is skipped.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with BOARD_GROUP_ID or
  # USER_ID:
  #   rake board_images:stamp_back_tiles                              # preview all
  #   DRY_RUN=false rake board_images:stamp_back_tiles                # apply all
  #   DRY_RUN=true BOARD_GROUP_ID=111 rake board_images:stamp_back_tiles
  #   DRY_RUN=false USER_ID=42 rake board_images:stamp_back_tiles
  desc "Flag back/sideways navigation tiles in board sets (DRY_RUN=false to apply; BOARD_GROUP_ID=N or USER_ID=N to scope)"
  task stamp_back_tiles: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    groups = BoardGroup.where.not(root_board_id: nil)
    groups = groups.where(id: ENV["BOARD_GROUP_ID"]) if ENV["BOARD_GROUP_ID"].present?
    groups = groups.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    stamped = 0
    groups_touched = 0

    groups.find_each do |group|
      tiles = Boards::BackTileStamper.new(group, dry_run: dry_run).call
      next if tiles.blank?

      groups_touched += 1
      stamped += tiles.size
      puts "#{dry_run ? '[DRY RUN] ' : ''}set ##{group.id} #{group.name.inspect}:"
      tiles.each do |board_image|
        puts "  board ##{board_image.board_id} tile #{board_image.label.inspect} " \
             "-> board ##{board_image.predictive_board_id}"
      end
    end

    if dry_run
      puts "\nDry run only — #{stamped} tile(s) across #{groups_touched} set(s) would be " \
           "flagged as back tiles. Re-run with DRY_RUN=false to apply."
    else
      puts "\nFlagged #{stamped} back tile(s) across #{groups_touched} set(s)."
    end
  end
end
