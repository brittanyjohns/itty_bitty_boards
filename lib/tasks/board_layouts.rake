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

  # Resets multi-cell tiles back to one cell and re-lays the board out in
  # reading order, for boards formatted before AiBoardFormatter stopped letting
  # the model choose a tile size.
  #
  # A wide tile puts a board's tile count out of step with its grid — 48 tiles
  # on 8 columns stops being 6 exact rows and becomes 7, the last one nearly
  # empty — and because `rows_for_screen_size` is `max(y + h)`, that extra row
  # silently defeats `settings["disable_scroll"]`: the frontend unlocks the
  # board rather than squash its rows below a readable height.
  #
  # Re-running "Format with AI" also repairs a board now, but costs an OpenAI
  # call and re-orders it. This is the pure-geometry fix: order is preserved.
  #
  # BOARD_IDS IS REQUIRED AND THERE IS NO SWEEP-EVERYTHING MODE. A user can
  # hand-author a wide tile in the editor (`save_layout!` persists whatever the
  # client sends), so a blanket reset would flatten deliberate layouts. Name the
  # boards you mean.
  #
  #   BOARD_IDS=6404 rake board_layouts:normalize_tile_sizes             # dry run
  #   BOARD_IDS=at-the-park,6405 DRY_RUN=false rake board_layouts:normalize_tile_sizes
  desc "Reset multi-cell tiles to 1x1 and re-lay boards in reading order (BOARD_IDS=id,slug required; DRY_RUN=false to apply)"
  task normalize_tile_sizes: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    keys = ENV["BOARD_IDS"].to_s.split(",").map(&:strip).reject(&:blank?)
    abort("BOARD_IDS is required (comma-separated board ids or slugs).") if keys.empty?

    ids, slugs = keys.partition { |k| k.match?(/\A\d+\z/) }
    boards = Board.where(id: ids).or(Board.where(slug: slugs)).to_a
    missing = keys - boards.flat_map { |b| [b.id.to_s, b.slug] }
    puts "Not found: #{missing.join(', ')}" if missing.any?

    boards.each do |board|
      rows_before = board.rows_for_screen_size("lg")
      wide = board.board_images.select do |bi|
        (bi.layout || {}).values.any? { |cell| cell.is_a?(Hash) && (cell["w"].to_i > 1 || cell["h"].to_i > 1) }
      end

      if wide.empty?
        puts "board ##{board.id} #{board.name.inspect}: already uniform (#{rows_before} rows) — skipped"
        next
      end

      labels = wide.map { |bi| "#{bi.label} #{bi.layout.dig('lg', 'w')}x#{bi.layout.dig('lg', 'h')}" }
      if dry_run
        puts "[DRY RUN] board ##{board.id} #{board.name.inspect}: #{wide.size} multi-cell tile(s) — #{labels.join(', ')} (#{rows_before} rows)"
        next
      end

      # Flatten every screen's cell first: calculate_grid_layout_for_screen_size
      # carries a tile's existing w/h forward even on a reset, so zeroing here is
      # what makes the re-lay uniform. Order is untouched — it re-slices
      # board_images by `position`.
      board.board_images.each do |bi|
        next if bi.layout.blank?

        bi.layout.each_value do |cell|
          next unless cell.is_a?(Hash)
          cell["w"] = 1
          cell["h"] = 1
        end
        bi.skip_create_voice_audio = true
        bi.save!
      end
      board.board_images.reset
      board.reset_layouts

      rows_after = board.reload.rows_for_screen_size("lg")
      puts "board ##{board.id} #{board.name.inspect}: normalized #{wide.size} tile(s) — #{labels.join(', ')}; rows #{rows_before} -> #{rows_after}"
      board.run_generate_preview_job
    end

    puts "Dry run only — re-run with DRY_RUN=false to apply." if dry_run
  end
end
