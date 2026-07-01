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
end
