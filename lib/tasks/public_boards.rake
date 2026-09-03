namespace :public_boards do
  # Duplicates in the public library are DATA, not seeds: `numbers` x2,
  # `I feel` x2, `Going to the Zoo` x2, `Lunch and Snack` x2 all accumulated
  # through the admin UI. `Board.public_starter_boards` stops them reaching a
  # public page; this retires them from the library for good.
  #
  # Retiring means clearing `predefined`, NOT unpublishing and NOT destroying.
  # `Board.public_boards` filters on `predefined`, so that alone takes a board
  # out of the library — while `/pb/<slug>` keeps resolving (`viewable_by?`
  # reads `published`), no printed QR dies, and `Boards::MarketplaceProtection`
  # is never tripped. `boards` has no soft delete, so a destroy here would be
  # unrecoverable; this is one column and one `update_column` back.
  #
  #   bin/rails public_boards:dedupe                 # dry run, prints the plan
  #   DRY_RUN=false bin/rails public_boards:dedupe   # applies it
  desc "Retire duplicate boards from the public library (dry run by default)"
  task dedupe: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    groups = Board.public_boards
                  .includes(:board_images)
                  .group_by { |board| Board.normalized_board_name(board.name) }
                  .select { |_name, boards| boards.size > 1 }

    if groups.empty?
      puts "[public_boards:dedupe] no duplicate names in the public library."
      next
    end

    protected_ids = Boards::MarketplaceProtection.protected_board_ids(
      groups.values.flatten.map(&:id)
    )

    retired = 0
    kept = 0
    skipped = 0

    puts "[public_boards:dedupe] #{groups.size} duplicated name(s) (dry_run=#{dry_run})"

    groups.sort_by(&:first).each do |name, boards|
      # Keeper: the richest board, tie-broken by the oldest id. A `myspeak`-
      # tagged board always wins — it is what the starter list and the
      # onboarding wizard's picker resolve through, so retiring one would
      # change what every new page offers.
      keeper = boards.min_by do |board|
        [board.tags.to_a.include?("myspeak") ? 0 : 1, -board.board_images.size, board.id]
      end
      kept += 1

      puts "  #{name}"
      puts "    KEEP    ##{keeper.id} #{keeper.name.inspect} (#{keeper.board_images.size} tiles, /pb/#{keeper.slug})"

      (boards - [keeper]).each do |board|
        if protected_ids.include?(board.id)
          skipped += 1
          puts "    SKIP    ##{board.id} #{board.name.inspect} — backs a marketplace printable"
          next
        end

        retired += 1
        puts "    RETIRE  ##{board.id} #{board.name.inspect} (#{board.board_images.size} tiles, /pb/#{board.slug})"
        # update_column: no callbacks, no validations, no touch — the row stays
        # byte-identical apart from the one flag, so nothing downstream that
        # keys on updated_at churns.
        board.update_column(:predefined, false) unless dry_run
      end
    end

    puts "[public_boards:dedupe] keepers=#{kept} retired=#{retired} skipped=#{skipped}"
    puts "(dry run — nothing was written; re-run with DRY_RUN=false to apply)" if dry_run
    puts "Undo a retirement with: Board.find(<id>).update_column(:predefined, true)"
  end

  desc "Print the curated list a public page with no starred boards would show"
  task starter_preview: :environment do
    boards = Board.public_starter_boards
    puts "[public_boards:starter_preview] limit=#{Board.public_starter_limit} " \
         "library=#{Board.public_boards.count} showing=#{boards.size}"
    boards.each_with_index do |board, i|
      tags = board.tags.to_a.join(",")
      puts "  #{i + 1}. ##{board.id} #{board.name.inspect} /pb/#{board.slug}" \
           "#{" [#{tags}]" if tags.present?}"
    end
  end
end
