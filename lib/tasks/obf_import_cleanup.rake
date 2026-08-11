namespace :obf_import do
  # Fallout from the silent .obf import failure (#656).
  #
  # Two leftovers, both harmless on their own and both worth clearing:
  #
  # 1. Boards parked in the retired `importing` status. ImportFromObfJob used
  #    to write `importing` -> `active`/`error`; it now writes the vocabulary
  #    the progress page polls (`processing` -> `complete`/`failed`). A board
  #    still saying `importing` never reached either end. One with tiles got
  #    its content and lost only the final status write, so it is `complete`;
  #    one with no tiles is an empty husk from a run that died, so it is
  #    `failed`. Nothing is deleted — an empty board is still the user's, and
  #    they can see it and remove it themselves.
  #
  # 2. Boards saved with a blank slug. `boards.slug` defaults to "" and
  #    `validates :slug, uniqueness: true` does not skip blanks, so the FIRST
  #    such row silently blocks every later board that tries to save without
  #    one. That is the actual bug this cleans up after; backfilling the slugs
  #    removes the landmine for any code path that forgets to generate one.
  #
  #   bin/rails obf_import:cleanup                    # preview (default)
  #   DRY_RUN=false bin/rails obf_import:cleanup      # apply
  desc "Repair boards left stuck by the silent .obf import failure (DRY_RUN=false to apply)"
  task cleanup: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    prefix = dry_run ? "[DRY RUN] " : ""

    stuck = Board.where(status: "importing").order(:id)
    puts "Boards stuck in the retired 'importing' status: #{stuck.count}"

    repaired = Hash.new(0)
    stuck.find_each do |board|
      tile_count = board.board_images.count
      target = tile_count.positive? ? "complete" : "failed"
      repaired[target] += 1

      puts "#{prefix}board ##{board.id} #{board.name.inspect} " \
           "(user #{board.user_id}, #{tile_count} tiles) importing -> #{target}"

      # update_column: this is a status correction, not a content edit. A full
      # save would fire the board's before_save chain (layout, parent, voice)
      # on a row nobody asked us to touch.
      board.update_column(:status, target) unless dry_run
    end

    blank_slugs = Board.where(slug: [nil, ""]).order(:id)
    puts
    puts "Boards saved without a slug: #{blank_slugs.count}"

    backfilled = 0
    blank_slugs.find_each do |board|
      begin
        board.generate_unique_slug
      rescue => e
        puts "  board ##{board.id}: could not build a slug (#{e.message}) — skipped"
        next
      end
      next if board.slug.blank?

      backfilled += 1
      puts "#{prefix}board ##{board.id} #{board.name.inspect} slug -> #{board.slug.inspect}"
      # A dry run writes nothing, so generate_unique_slug can't see the slugs
      # it just handed out — two same-named boards will preview the same slug
      # and get distinct ones on the real run.
      board.update_column(:slug, board.slug) unless dry_run
    end

    puts
    puts "#{prefix}marked complete: #{repaired['complete']}, " \
         "marked failed: #{repaired['failed']}, slugs backfilled: #{backfilled}"
    puts "Re-run with DRY_RUN=false to apply." if dry_run
  end
end
