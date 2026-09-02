namespace :board_assignments do
  desc "Replace legacy per-communicator assignment clones with their source board (dry run by default; DRY_RUN=false to apply)"
  task consolidate: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    limit = ENV["LIMIT"].presence&.to_i

    scope = ChildBoard.where.not(original_board_id: nil)
                      .joins(:board).where(boards: { is_template: true })
                      .order(:id)
    scope = scope.limit(limit) if limit

    total = scope.count
    puts "[board_assignments:consolidate] #{dry_run ? 'DRY RUN' : 'APPLYING'} — #{total} legacy assignment tile(s) to consider"
    puts "  (dry run writes nothing; re-run with DRY_RUN=false to apply)" if dry_run

    tally = Hash.new(0)
    boards_destroyed = 0

    scope.find_each do |child_board|
      result = Boards::AssignmentConsolidator.new(child_board, dry_run: dry_run).call
      key = result.status == :consolidated ? :consolidated : result.reason
      tally[key] += 1
      boards_destroyed += result.boards_destroyed.to_i

      if result.status == :consolidated
        puts "  ✓ child_board=#{child_board.id} account=#{child_board.child_account_id} " \
             "clone=#{child_board.board_id} → source=#{child_board.original_board_id} " \
             "(#{result.boards_destroyed} board(s) #{dry_run ? 'would be' : ''} removed)"
      else
        puts "  · skip child_board=#{child_board.id} clone=#{child_board.board_id} — #{result.reason}"
      end
    rescue => e
      tally[:error] += 1
      puts "  ! child_board=#{child_board.id} failed: #{e.class}: #{e.message}"
      Rails.logger.error "[board_assignments:consolidate] child_board #{child_board.id}: #{e.message}"
    end

    puts
    puts "[board_assignments:consolidate] summary"
    tally.sort_by { |k, _| k.to_s }.each { |reason, count| puts "  #{reason}: #{count}" }
    puts "  clone boards #{dry_run ? 'that would be ' : ''}destroyed: #{boards_destroyed}"
    puts
    puts "  Skip reasons:"
    puts "    edited              — the clone diverges from its source; consolidating would discard real edits."
    puts "    source_gone         — the board it was copied from no longer exists."
    puts "    source_not_visible  — the source is not something this communicator's owner may hold."
    puts "    marketplace_protected — a board in the clone tree backs a sold printable."
    puts "    not_a_legacy_clone  — already an ordinary attached board; nothing to do."
    puts
    puts "  Note: a consolidated tile now serves the SOURCE board, so the clone's own"
    puts "  /pb/<slug> stops resolving. Consolidation publishes the source for a"
    puts "  favorited tile so the MySpeak card keeps working at the source's slug."
  end
end
