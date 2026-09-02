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

  desc "Read-only: for every legacy clone skipped as `edited`, report WHICH field diverged"
  task diff_report: :environment do
    limit = ENV["LIMIT"].presence&.to_i
    samples = (ENV["SAMPLES"].presence || 8).to_i

    scope = ChildBoard.where.not(original_board_id: nil)
                      .joins(:board).where(boards: { is_template: true })
                      .order(:id)
    scope = scope.limit(limit) if limit

    field_tally = Hash.new(0)   # field => clones diverging on it
    shape_tally = Hash.new(0)   # structural mismatches
    examined = 0
    examples = []

    scope.find_each do |child_board|
      clone_root = child_board.board
      source = Board.find_by(id: child_board.original_board_id)
      next if clone_root.nil? || !clone_root.is_template? || source.nil?

      clone_tree = Boards::AssignmentConsolidator.tree(clone_root)
      source_tree = Boards::AssignmentConsolidator.tree(source)

      if clone_tree.size != source_tree.size
        shape_tally[:board_count] += 1
        next
      end

      fields = Set.new
      names = Set.new
      tile_counts = false

      clone_tree.zip(source_tree).each do |clone_board, source_board|
        names << :board_name if clone_board.name != source_board.name

        clone_tiles = clone_board.board_images.order(:position, :id).to_a
        source_tiles = source_board.board_images.order(:position, :id).to_a
        if clone_tiles.size != source_tiles.size
          tile_counts = true
          next
        end

        clone_tiles.zip(source_tiles).each do |ct, st|
          cf = Boards::AssignmentConsolidator.tile_fields(ct)
          sf = Boards::AssignmentConsolidator.tile_fields(st)
          cf.each_key { |k| fields << k if cf[k] != sf[k] }
        end
      end

      shape_tally[:tile_count] += 1 if tile_counts
      names.each { |n| shape_tally[n] += 1 }
      next if fields.empty? && names.empty? && !tile_counts

      examined += 1
      fields.each { |f| field_tally[f] += 1 }

      if examples.size < samples
        examples << { cb: child_board.id, clone: clone_root.id, source: source.id,
                      fields: fields.to_a.sort, shape: (names.to_a + (tile_counts ? [:tile_count] : [])) }
      end
    end

    puts "[board_assignments:diff_report] #{examined} clone(s) differ from their source"
    puts
    puts "  Structural differences (a page or tile was added/removed/renamed):"
    if shape_tally.empty?
      puts "    none"
    else
      shape_tally.sort_by { |_, v| -v }.each { |k, v| puts "    #{k}: #{v}" }
    end
    puts
    puts "  Per-field divergence (a clone can appear in several rows):"
    if field_tally.empty?
      puts "    none"
    else
      field_tally.sort_by { |_, v| -v }.each { |k, v| puts "    #{k}: #{v}" }
    end
    puts
    puts "  Sample:"
    examples.each do |e|
      puts "    child_board=#{e[:cb]} clone=#{e[:clone]} source=#{e[:source]} " \
           "fields=#{e[:fields].join(',').presence || '-'} shape=#{e[:shape].join(',').presence || '-'}"
    end
    puts
    puts "  Reading this: `label`, `bg_color`, `hidden`, `layout` and any structural"
    puts "  row are real user edits. `display_image_url` alone usually is not — a"
    puts "  clone froze a snapshot of the library art at assignment time, so the"
    puts "  source may simply have newer art."
  end
end
