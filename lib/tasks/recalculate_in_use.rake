namespace :boards do
  # Backfill for two historical in_use drifts:
  #   1. Builder roots stuck at false — the ChildBoard attach happens after the
  #      root's last save, so check_in_use never saw it (fixed by ChildBoard's
  #      recalculate_boards_in_use callback going forward).
  #   2. Unrelated boards stuck at true — check_in_use on a NEW record ran with
  #      a nil id, so `where(original_board_id: nil)` matched every
  #      direct-attach row and marked every brand-new board in_use (fixed by
  #      the nil-id guard in Board#assigned_to_communicator?).
  #
  # Read-only by default. Apply with DRY_RUN=false.
  desc "Recompute Board.in_use from child_boards rows, both directions (DRY_RUN=false to apply)"
  task recalculate_in_use: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    attached_ids = ChildBoard.pluck(:board_id, :original_board_id).flatten.compact.uniq

    should_be_true = Board.where(in_use: false, id: attached_ids)
    should_be_false = Board.where(in_use: true).where.not(id: attached_ids)

    puts "Boards attached to a communicator but in_use=false: #{should_be_true.count}"
    puts "Boards not attached to any communicator but in_use=true: #{should_be_false.count}"

    if dry_run
      puts "DRY RUN — no changes. Re-run with DRY_RUN=false to apply."
      next
    end

    # The flag is derived state; update_all skips the unrelated save callbacks.
    flipped_on = should_be_true.update_all(in_use: true, updated_at: Time.current)
    flipped_off = should_be_false.update_all(in_use: false, updated_at: Time.current)
    puts "Done. Set in_use=true on #{flipped_on} boards, in_use=false on #{flipped_off} boards."
  end
end
