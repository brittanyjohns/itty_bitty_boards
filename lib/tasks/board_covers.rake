namespace :board_covers do
  # Backfill the single display-image switch (settings["display_image_source"])
  # for boards created before it existed, then drop the retired flags
  # (display_image_is_custom / display_follows_preview). Resolution already
  # infers the right source at read time (Board#display_image_source), so this
  # task is a cleanup — correctness does not depend on running it.
  #
  # A board is "custom" when it has an uploaded cover (preset_display_image
  # attached) or the legacy display_image_is_custom flag; everything else is
  # "preview".
  #
  # Read-only by default (reports what would change). Apply with DRY_RUN=false.
  # Scope to one owner with USER_ID=N.
  #
  #   rake board_covers:backfill_source                       # dry run, all
  #   DRY_RUN=false rake board_covers:backfill_source         # apply all
  #   DRY_RUN=false USER_ID=740 rake board_covers:backfill_source
  desc "Backfill settings.display_image_source + drop legacy flags (DRY_RUN=false to apply; USER_ID=N to scope)"
  task backfill_source: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    scope = Board.all
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    to_custom = 0
    to_preview = 0
    flags_cleared = 0

    scope.find_each do |board|
      settings = board.settings.is_a?(Hash) ? board.settings.dup : {}
      had_legacy_flags = settings.key?("display_image_is_custom") || settings.key?("display_follows_preview")
      already_set = Board::DISPLAY_IMAGE_SOURCES.include?(settings["display_image_source"])

      # Compute the source before stripping the legacy flags (inference reads them).
      resolved = board.display_image_source

      next unless had_legacy_flags || !already_set

      settings.delete("display_image_is_custom")
      settings.delete("display_follows_preview")
      settings["display_image_source"] = resolved

      resolved == "custom" ? (to_custom += 1) : (to_preview += 1)
      flags_cleared += 1 if had_legacy_flags

      unless dry_run
        board.update_columns(settings: settings) # skip validations/callbacks — data cleanup only
      end
    end

    verb = dry_run ? "would set" : "set"
    puts "board_covers:backfill_source — #{verb}: #{to_custom} custom, #{to_preview} preview; legacy flags cleared on #{flags_cleared} board(s)."
    puts "(dry run — re-run with DRY_RUN=false to apply)" if dry_run
  end

  # Re-render the cover PNG for boards whose cached cover was generated while
  # Boards::BoardPdfLayoutNormalizer wrongly resolved art for BLANKED tiles.
  #
  # A board_image with display_image_url = "" means "this tile has no picture" —
  # the app draws the word over the tile's bg_color. The normalizer used to
  # `.presence` that marker away and fall through to the underlying image's
  # library art, so every Grover render (cover PNG, downloadable PDF, printables)
  # printed a symbol the app never shows: an apple on the "red" colour tile.
  # The renderer is fixed; the covers are cached artifacts and stay wrong until
  # they're regenerated, which is what this does.
  #
  # Only boards that actually render wrong are touched — a blanked tile whose
  # image has no src_url looked the same before and after the fix.
  # GenerateBoardPreviewJob skips builder_child sub-boards on its own, so no
  # extra filtering is needed here.
  #
  # These are Grover (headless Chrome) renders, so a large batch is real Sidekiq
  # load. Read the dry-run count before applying.
  #
  #   rake board_covers:refresh_blanked_tile_covers                # dry run, all
  #   DRY_RUN=false rake board_covers:refresh_blanked_tile_covers  # apply all
  #   DRY_RUN=false USER_ID=740 rake board_covers:refresh_blanked_tile_covers
  desc "Re-render covers for boards with blanked tiles that used to print borrowed art (DRY_RUN=false to apply; USER_ID=N to scope)"
  task refresh_blanked_tile_covers: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    scope = Board.where(
      id: BoardImage.joins(:image)
                    .where(display_image_url: "")
                    .where.not(images: { src_url: [nil, ""] })
                    .select(:board_id),
    )
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    total = scope.count
    puts "board_covers:refresh_blanked_tile_covers — #{total} board(s) with blanked tiles over arted images."

    if dry_run
      puts "(dry run — re-run with DRY_RUN=false to enqueue #{total} Grover render(s))"
      next
    end

    enqueued = 0
    scope.find_each do |board|
      GenerateBoardPreviewJob.perform_async(board.id, { "generate_png" => true })
      enqueued += 1
    end

    puts "board_covers:refresh_blanked_tile_covers — enqueued #{enqueued} preview render(s)."
  end

  # Render the cover for boards that have tiles but no cover at all — the
  # backlog left by Board#clone_with_images, whose preview enqueue was guarded
  # on a stale counter cache and so never fired for any cloned board. Those
  # boards show as a placeholder everywhere a cover is drawn, including the
  # public MySpeak page's board grid.
  #
  # Selection is by OUTCOME, not by provenance: no preview attachment and a
  # blank display_image_url column means Board#display_image_url has nothing to
  # return, whatever created the board. Boards with no tiles are excluded —
  # there is nothing to render, and Board#preview_generation_blocker refuses
  # them anyway.
  #
  # builder_child sub-boards are skipped here rather than left to the job's own
  # skip: a board set renders ONE preview (the root) and thumbnails every other
  # page from the folder tile that opens it, so enqueuing them is pure queue
  # volume for a render that is discarded.
  #
  # Enqueue goes through run_generate_preview_job, not a bare perform_async, so
  # the render is marked `queued` (what clients poll) and carries
  # hide_header — a direct push produces a cover WITH a header, unlike every
  # other caller in the app.
  #
  # These are Grover (headless Chrome) renders, so a large batch is real Sidekiq
  # load. Read the dry-run count first, and use LIMIT to stage it.
  #
  #   rake board_covers:render_missing                       # dry run, all
  #   DRY_RUN=false LIMIT=200 rake board_covers:render_missing
  #   DRY_RUN=false USER_ID=740 rake board_covers:render_missing
  desc "Render covers for boards that have tiles but no cover (DRY_RUN=false to apply; LIMIT=N, USER_ID=N to scope)"
  task render_missing: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    limit = ENV["LIMIT"].presence&.to_i

    # Excluded via a subquery rather than `where.not("settings @> ?", …)`:
    # boards.settings has no NOT NULL constraint, and `NULL @> x` is NULL, so
    # negating it inline would silently drop every board with nil settings —
    # which is exactly the set most likely to be missing a cover.
    builder_children = Board.where("settings @> ?", { builder_child: true }.to_json)

    scope = Board.where.missing(:preview_image_attachment)
                 .where(display_image_url: [nil, ""])
                 .where(id: BoardImage.select(:board_id))
                 .where.not(id: builder_children)
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    total = scope.count
    puts "board_covers:render_missing — #{total} board(s) with tiles and no cover."

    if dry_run
      target = limit ? [limit, total].min : total
      puts "(dry run — re-run with DRY_RUN=false to enqueue #{target} Grover render(s))"
      next
    end

    enqueued = 0
    scope.find_each do |board|
      break if limit && enqueued >= limit

      board.run_generate_preview_job
      enqueued += 1
    end

    puts "board_covers:render_missing — enqueued #{enqueued} preview render(s)."
  end
end
