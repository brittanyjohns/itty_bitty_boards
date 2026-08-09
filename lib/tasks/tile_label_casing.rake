namespace :labels do
  # Backfill for the casing defect fixed in Labels::CaseNormalizer: a plain
  # leading capital ("Fun", "Giraffe") used to be read as DELIBERATE styling, so
  # the lowercase default never applied and the capital stuck permanently — on
  # the tile AND on the Image it defaulted from. Boards built before the fix
  # still render that way, because tile text is written once at creation.
  #
  # Only ever folds a leading capital down. A word whose casing was deliberate
  # ("iPad", "TV", "McDonald's", "HELP") and the standalone pronoun "I" are left
  # exactly as they are — the same judgement Labels::CaseNormalizer makes, reused
  # here rather than re-implemented, so the backfill and the live path can't drift.
  #
  # LINKED (folder / predictive) TILES ARE SKIPPED BY DEFAULT. A category tile's
  # capital is authored on purpose — "Food" is a folder you open, not a word you
  # speak — and `predictive_board_id` cannot tell a curated folder apart from a
  # predictive word tile, so the conservative default is to leave every linked
  # tile alone. INCLUDE_LINKED=1 folds them too.
  #
  #   bin/rails labels:fold_casing_report              # dry run, whole database
  #   bin/rails labels:fold_casing_report BOARD_ID=5827
  #   bin/rails labels:fold_casing APPLY=1 BOARD_ID=5827
  #   bin/rails labels:fold_casing APPLY=1             # everything
  #
  # Env: BOARD_ID, USER_ID (scope) · INCLUDE_LINKED=1 · IMAGES=0 (tiles only)
  #      LIMIT (cap rows touched) · SAMPLE (rows to print, default 25)
  #      ONLY=down (just fold stuck capitals) | up | both (default)

  # A rewrite is only ever a re-casing: same letters, different capitals.
  # Anything else means the normalizer would change the word itself, so we
  # refuse it — this must never edit what a tile SAYS, only how it's cased.
  recase_only = lambda do |old, new|
    new.present? && new != old && new.casecmp(old).zero?
  end

  # Which way a rewrite moves. Folding a stuck capital down ("Fun" -> "fun") is
  # the defect being repaired; the normalizer ALSO capitalizes the standalone
  # pronoun "i" ("i need" -> "I need"), which is a grammar rule moving the other
  # way. Both converge on what the live path now produces, but they are
  # different edits and are reported — and can be run — separately.
  direction = lambda do |old, new|
    new.count("A-Z") < old.count("A-Z") ? :down : :up
  end

  # Read inside the lambda, not at file-load time: a rake file is loaded once
  # per process, so a local captured out here would freeze whatever ENV held
  # before the task ran and silently ignore ONLY=.
  keep_direction = lambda do |dir|
    wanted = (ENV["ONLY"].presence || "both").downcase
    wanted == "both" || wanted == dir.to_s
  end

  scope_tiles = lambda do
    # reorder(nil): board_images carries a default position order, and find_each
    # overrides it — without this every batch logs "Scoped order is ignored".
    # Order is irrelevant here; each row is folded independently.
    rel = BoardImage.reorder(nil).where.not(display_label: [nil, ""])
    rel = rel.where(board_id: ENV["BOARD_ID"]) if ENV["BOARD_ID"].present?
    rel = rel.joins(:board).where(boards: { user_id: ENV["USER_ID"] }) if ENV["USER_ID"].present?
    rel = rel.where(predictive_board_id: nil) unless ENV["INCLUDE_LINKED"] == "1"
    rel
  end

  scope_images = lambda do
    rel = Image.where.not(display_label: [nil, ""])
    rel = rel.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?
    # An image is not board-scoped; when a single board is named, only the
    # images that board's tiles actually point at are in play.
    rel = rel.where(id: BoardImage.where(board_id: ENV["BOARD_ID"]).select(:image_id)) if ENV["BOARD_ID"].present?
    rel
  end

  # Yields [record, old_text, new_text] for every row the fold would rewrite.
  collect = lambda do |apply:|
    limit = ENV["LIMIT"].presence&.to_i
    changes = { tiles: [], images: [] }

    scope_tiles.call.includes(:image).find_each do |bi|
      break if limit && changes[:tiles].size >= limit

      old = bi.display_label.to_s
      new = Labels::CaseNormalizer.normalize(
        old, language: bi.language, part_of_speech: bi.effective_part_of_speech,
      )
      next unless recase_only.call(old, new)

      dir = direction.call(old, new)
      next unless keep_direction.call(dir)

      changes[:tiles] << [bi, old, new, dir]
      bi.update_columns(display_label: new) if apply
    end

    unless ENV["IMAGES"] == "0"
      scope_images.call.find_each do |img|
        break if limit && changes[:images].size >= limit

        old = img.display_label.to_s
        new = Labels::CaseNormalizer.normalize(old, part_of_speech: img.part_of_speech)
        next unless recase_only.call(old, new)

        dir = direction.call(old, new)
        next unless keep_direction.call(dir)

        changes[:images] << [img, old, new, dir]
        # update_columns, not update!: this must not fire set_label, the audio
        # re-render hooks, or touch updated_at across the library.
        img.update_columns(display_label: new) if apply
      end
    end

    changes
  end

  report = lambda do |changes, applied:|
    sample = (ENV["SAMPLE"].presence || 25).to_i
    verb = applied ? "rewrote" : "would rewrite"

    %i[tiles images].each do |kind|
      rows = changes[kind]
      down, up = rows.partition { |row| row[3] == :down }
      puts "\n#{kind.to_s.capitalize}: #{verb} #{rows.size} " \
           "(#{down.size} stuck capital folded down, #{up.size} standalone \"i\" capitalized)"
      next if rows.empty?

      { "fold down" => down, "capitalize i" => up }.each do |heading, group|
        next if group.empty?

        puts "  #{heading}:"
        group.first(sample).each do |record, old, new, _dir|
          where = kind == :tiles ? "board #{record.board_id}" : "image #{record.id}"
          puts format("    %-20s %-18s -> %s", where, old.inspect, new.inspect)
        end
        puts "    … #{group.size - sample} more" if group.size > sample
      end
    end

    scope = []
    scope << "board #{ENV['BOARD_ID']}" if ENV["BOARD_ID"].present?
    scope << "user #{ENV['USER_ID']}" if ENV["USER_ID"].present?
    scope << (ENV["INCLUDE_LINKED"] == "1" ? "including linked tiles" : "skipping linked tiles")
    scope << "direction=#{ENV['ONLY'].presence || 'both'}"
    puts "\nScope: #{scope.join(', ')}"
  end

  desc "Report tile/image display text with a stuck accidental capital (writes nothing)"
  task fold_casing_report: :environment do
    puts "DRY RUN — nothing is written."
    report.call(collect.call(apply: false), applied: false)
    puts "\nRe-run with APPLY=1 on labels:fold_casing to write these changes."
  end

  desc "Fold accidental leading capitals out of tile/image display text (APPLY=1 to write)"
  task fold_casing: :environment do
    apply = ENV["APPLY"] == "1"
    puts apply ? "APPLYING changes." : "DRY RUN — nothing is written (pass APPLY=1 to write)."

    changes = collect.call(apply: apply)
    report.call(changes, applied: apply)

    if apply
      total = changes[:tiles].size + changes[:images].size
      puts "\nDone. #{total} row(s) updated."
    end
  end
end
