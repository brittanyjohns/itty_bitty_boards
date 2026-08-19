namespace :obf_import do
  # Backfill for every set imported (or seeded) before
  # Boards::ImportedSetClassifier existed.
  #
  # An import writes its tile links with update_columns and only after every
  # board in the package exists, so Board#check_is_sub_board never ran against
  # the finished graph: all 30 pages of a core set are main boards, while the
  # ROOT drifts the other way — the first unrelated save sees the pages' ways
  # home pointing at it and demotes it. This settles both halves: root pinned as
  # a main board, its pages marked sub-boards.
  #
  # Roots come from the two places a set records one: BoardGroup#root_board_id
  # (a user .obz import) and the robust-set marker on a seeded Core 60/84 root
  # (settings["board_builder_robust"] — those have no BoardGroup).
  #
  #   bin/rails obf_import:classify_sets                   # preview (default)
  #   DRY_RUN=false bin/rails obf_import:classify_sets     # apply
  desc "Collapse imported board sets to their root board (DRY_RUN=false to apply)"
  task classify_sets: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    prefix = dry_run ? "[DRY RUN] " : ""

    group_roots = BoardGroup.where.not(root_board_id: nil).pluck(:root_board_id, :id).to_h
    roots = Board.where(id: group_roots.keys).order(:id).to_a
    roots += Boards::RobustSets.all_roots.reject { |b| roots.any? { |r| r.id == b.id } }

    puts "Imported set roots found: #{roots.size}"

    demoted = 0
    roots.each do |root|
      group_id = group_roots[root.id]
      member_ids = group_id ? BoardGroup.find_by(id: group_id)&.board_ids : nil

      page_ids = Boards::ImportedSetClassifier.new(
        root,
        member_ids: member_ids,
        dry_run: dry_run,
      ).call

      already_sub = Board.where(id: page_ids, sub_board: true).count
      changing = page_ids.size - already_sub
      demoted += changing

      puts "#{prefix}root ##{root.id} #{root.name.inspect} " \
           "(user #{root.user_id}, #{group_id ? "group #{group_id}" : "walked"}) " \
           "-> main board; #{page_ids.size} pages, #{changing} newly demoted"
    end

    puts
    puts "#{prefix}#{roots.size} roots pinned, #{demoted} pages demoted to sub-boards"
    puts "Re-run with DRY_RUN=false to apply." if dry_run
  end
end
