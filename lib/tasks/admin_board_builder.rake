namespace :admin_board_builder do
  # Backfill for the folder-tile muting fix in Boards::AdminBuilder::Build:
  # a tile that opens another page is a door, not a word, so it navigates
  # without speaking its label. Sets built before that fix speak "food" on the
  # way to the food page — a word the communicator never chose to say — because
  # tile data is written once at build time.
  #
  # This sets data["mute_name"] = true on every linked tile across every board
  # the admin Board Builder created, which is what a new build now does inline.
  # No self-tile exception: nothing in an admin-built set is a you-are-here
  # anchor, so a child's "back to home" tile is muted too. (The COMMUNICATOR
  # builder's equivalent is BuildBoardSetJob#mute_dynamic_tile_names!, which
  # does keep that exception — don't point this task at those sets.)
  #
  # Scoped through AdminBoardBuild.builder_boards, the same rail every admin
  # action on these boards runs on, so it can never reach a board this page
  # didn't create.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with BUILD_ID=N:
  #   rake admin_board_builder:mute_folder_tiles                    # preview all
  #   DRY_RUN=false rake admin_board_builder:mute_folder_tiles      # apply all
  #   DRY_RUN=false BUILD_ID=12 rake admin_board_builder:mute_folder_tiles
  desc "Mute the names of linked tiles on admin-built boards (DRY_RUN=false to apply; BUILD_ID=N to scope)"
  task mute_folder_tiles: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    boards = AdminBoardBuild.builder_boards
    if ENV["BUILD_ID"].present?
      build = AdminBoardBuild.find(ENV["BUILD_ID"])
      boards = boards.where(id: build.set_boards.map(&:id))
    end

    names_by_board_id = boards.pluck(:id, :name).to_h

    # reorder(nil): board_images carries a default position order and find_each
    # overrides it, which logs "Scoped order is ignored" on every batch. Each
    # tile is muted independently, so order is irrelevant.
    tiles = BoardImage
      .reorder(nil)
      .where(board_id: names_by_board_id.keys)
      .where.not(predictive_board_id: nil)
      .where("predictive_board_id <> board_id")

    boards_touched = Set.new
    muted = 0

    tiles.find_each do |board_image|
      data = board_image.data || {}
      next if data["mute_name"] == true

      muted += 1
      boards_touched << board_image.board_id
      puts "#{dry_run ? '[DRY RUN] ' : ''}board ##{board_image.board_id} " \
           "#{names_by_board_id[board_image.board_id].inspect}: mute #{board_image.label.inspect} " \
           "(opens board ##{board_image.predictive_board_id})"

      next if dry_run

      # update_column: mute_name is display-only, and a full save would fire the
      # audio hooks and re-render every tile's speech for nothing.
      board_image.update_column(:data, data.merge("mute_name" => true))
    end

    if dry_run
      puts "\nDry run only — #{muted} linked tile(s) across #{boards_touched.size} board(s) " \
           "would be muted. Re-run with DRY_RUN=false to apply."
    else
      puts "\nMuted #{muted} linked tile(s) across #{boards_touched.size} board(s)."
    end
  end
end
