namespace :board_layouts do
  # Recompute proportional medium/small column counts and reflow the md/sm tile
  # layouts from each board's authored large layout, so existing boards read
  # well on tablets and phones (Boards::ScreenColumns + Boards::ScreenReflow).
  # The lg layout is never touched, and any screen the user hand-arranged
  # (settings["custom_screen_layouts"]) is left alone.
  #
  # Read-only by default (reports what would change). Apply with DRY_RUN=false.
  # Scope to one owner with USER_ID=N. Keep existing column counts (reflow only,
  # no column recompute) with KEEP_COLUMNS=true.
  #
  #   rake board_layouts:reflow_sm_md                         # dry run, all
  #   DRY_RUN=false rake board_layouts:reflow_sm_md           # apply all
  #   DRY_RUN=false USER_ID=740 rake board_layouts:reflow_sm_md
  desc "Reflow sm/md layouts + proportional columns for existing boards (DRY_RUN=false to apply; USER_ID=N to scope; KEEP_COLUMNS=true to skip column recompute)"
  task reflow_sm_md: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    keep_columns = ENV["KEEP_COLUMNS"] == "true"

    scope = Board.where(id: BoardImage.reorder(nil).select(:board_id).distinct)
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    boards_touched = 0
    boards_skipped = 0

    scope.find_each do |board|
      customized = Array(board.settings&.dig("custom_screen_layouts"))
      screens = Boards::ScreenReflow::DERIVED_SCREENS - customized
      if screens.empty?
        boards_skipped += 1
        next
      end

      lg = board.large_screen_columns.to_i
      lg = 12 if lg < 1
      changes = []

      unless keep_columns
        screens.each do |screen|
          col_attr = screen == "md" ? :medium_screen_columns : :small_screen_columns
          want = Boards::ScreenColumns.derive(lg, screen)
          next if board.public_send(col_attr).to_i == want

          changes << "#{screen} cols #{board.public_send(col_attr)}→#{want}"
          board.public_send("#{col_attr}=", want) unless dry_run
        end
        board.save! if !dry_run && changes.any?
      end

      reflowed = board.board_images.exists? ? screens : []
      next if reflowed.empty? && changes.empty?

      Boards::ScreenReflow.reflow!(board, screens: screens) unless dry_run
      boards_touched += 1

      kind = board.predefined? ? "predefined" : (board.settings&.dig("builder_root") ? "builder" : "board")
      detail = changes.any? ? " (#{changes.join(', ')})" : ""
      puts "#{dry_run ? '[DRY RUN] ' : ''}board ##{board.id} #{board.name.inspect} (#{kind}, owner #{board.user_id}): reflow #{reflowed.join('/')}#{detail}"

      board.run_generate_preview_job unless dry_run
    end

    summary = "#{boards_touched} board(s) to reflow, #{boards_skipped} skipped (fully customized)."
    puts(dry_run ? "Dry run only — #{summary} Re-run with DRY_RUN=false to apply." : "Reflowed #{summary}")
  end
end
