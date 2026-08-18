namespace :board_word_lists do
  # Backfill data["current_word_list"] for boards that never got one.
  #
  # `Board#word_sample` (rendered for every board in every card list, including
  # the ~1k-board `available_boards` array on GET /api/child_accounts/:id) falls
  # back to `set_current_word_list`, which queries board_images. Until
  # `set_current_word_list` was fixed to assign through `self.data =`, the
  # computed list was never persisted, so those boards re-queried on every
  # request forever. This task fills the backlog left behind by that bug.
  #
  # Read-only by default (reports what would change). Apply with DRY_RUN=false.
  # Scope to one owner with USER_ID=N.
  #
  #   rake board_word_lists:backfill                    # dry run, all
  #   DRY_RUN=false rake board_word_lists:backfill      # apply all
  #   DRY_RUN=false USER_ID=1 rake board_word_lists:backfill
  desc "Backfill data.current_word_list on boards missing it (DRY_RUN=false to apply; USER_ID=N to scope)"
  task backfill: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    scope = Board.where("data->'current_word_list' IS NULL")
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    total = scope.count
    puts "#{dry_run ? "[dry run] " : ""}#{total} board(s) missing current_word_list"

    filled = 0
    empty = 0
    failed = 0

    scope.find_each(batch_size: 200) do |board|
      words = board.set_current_word_list

      # A board with no tiles has nothing to cache — leave it null rather than
      # writing an empty array, so a later add_images run still populates it.
      if words.blank?
        empty += 1
        next
      end

      if dry_run
        filled += 1
        next
      end

      # Only the jsonb column changes; skip validations and callbacks so a board
      # that is invalid for unrelated reasons still gets its word list.
      board.update_column(:data, board.data)
      filled += 1
    rescue StandardError => e
      failed += 1
      warn "  board #{board.id}: #{e.class}: #{e.message}"
    end

    puts "#{dry_run ? "would fill" : "filled"}: #{filled}"
    puts "skipped (no tiles): #{empty}"
    puts "failed: #{failed}" if failed.positive?
    puts "Re-run with DRY_RUN=false to apply." if dry_run && filled.positive?
  end
end
