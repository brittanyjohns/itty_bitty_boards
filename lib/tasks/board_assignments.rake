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
  # `display_image_url` is the only field a clone can differ on without anyone
  # having chosen anything: it froze a snapshot of the library's art at
  # assignment time (of a possibly DIFFERENT Image row, since clone_with_images
  # re-resolves image_id by label for the new owner).
  ART_ONLY_FIELDS = %i[display_image_url].freeze

  task diff_report: :environment do
    limit = ENV["LIMIT"].presence&.to_i
    samples = (ENV["SAMPLES"].presence || 8).to_i

    scope = ChildBoard.where.not(original_board_id: nil)
                      .joins(:board).where(boards: { is_template: true })
    scope = scope.limit(limit) if limit

    field_tally = Hash.new(0)     # field => clones diverging on it
    shape_tally = Hash.new(0)     # structural mismatches
    bucket_tally = Hash.new(0)    # structural / content_edit / art_only
    unpaired_tally = Hash.new(0)
    examined = 0
    examples = []

    # Tiles keyed by label, keeping only labels that appear exactly once — an
    # ambiguous label is left unpaired rather than matched arbitrarily.
    unique_by_label = lambda do |tiles|
      tiles.group_by { |t| t.label.to_s.downcase }
           .filter_map { |label, group| [label, group.first] if group.size == 1 }
           .to_h
    end

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
      unpaired = 0

      clone_tree.zip(source_tree).each do |clone_board, source_board|
        names << :board_name if clone_board.name != source_board.name

        clone_tiles = clone_board.board_images.to_a
        source_tiles = source_board.board_images.to_a
        tile_counts = true if clone_tiles.size != source_tiles.size

        # Pair tiles by LABEL, not by position.
        #
        # Positional pairing compares tile A against tile B the moment a board's
        # tiles come back in a different order, and then every field diverges at
        # once — which is exactly the signature the first run produced
        # (bg_color + display_image_url + display_label + label + layout, all
        # together, on boards nobody could even find to edit). It inflated every
        # tally. Only labels unique on BOTH sides are trusted; anything else is
        # counted as unpaired and reported rather than guessed at.
        #
        # (The consolidator's own verdict never had this problem — it sorts
        # before comparing, so it is order-independent. This is attribution
        # only.)
        clone_by_label = unique_by_label.call(clone_tiles)
        source_by_label = unique_by_label.call(source_tiles)
        shared = clone_by_label.keys & source_by_label.keys
        leftover_clone = clone_tiles.size - shared.size
        unpaired += leftover_clone

        # A tile whose LABEL was changed cannot pair with anything, so it would
        # otherwise disappear from the tally entirely — the one way this
        # attribution could under-report an edit rather than over-report one.
        # Leftovers on both sides of a board whose tile counts match means a
        # label moved; record it and let the clone bucket as a content edit.
        if leftover_clone.positive? && (source_tiles.size - shared.size).positive? &&
           clone_tiles.size == source_tiles.size
          fields << :label
        end

        shared.each do |key|
          cf = Boards::AssignmentConsolidator.tile_fields(clone_by_label[key])
          sf = Boards::AssignmentConsolidator.tile_fields(source_by_label[key])
          cf.each_key { |k| fields << k if cf[k] != sf[k] }
        end
      end

      shape_tally[:tile_count] += 1 if tile_counts
      names.each { |n| shape_tally[n] += 1 }
      next if fields.empty? && names.empty? && !tile_counts

      examined += 1
      fields.each { |f| field_tally[f] += 1 }
      unpaired_tally[:clones_with_unpaired_tiles] += 1 if unpaired.positive?

      # The actionable split. `display_image_url` on its own is not a user edit:
      # the clone froze a snapshot of library art (or of a DIFFERENT library row,
      # since clone_with_images re-resolves image_id by label for the new owner).
      # Everything else in `content` is something a person chose.
      content = fields - ART_ONLY_FIELDS
      bucket =
        if !names.empty? || tile_counts then :structural
        elsif content.any?              then :content_edit
        elsif fields.any?               then :art_only
        end
      bucket_tally[bucket] += 1 if bucket

      if examples.size < samples
        examples << { cb: child_board.id, clone: clone_root.id, source: source.id,
                      bucket: bucket, unpaired: unpaired,
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
    puts "  What this means per clone (the actionable split):"
    if bucket_tally.empty?
      puts "    none"
    else
      %i[structural content_edit art_only].each do |b|
        next unless bucket_tally[b].positive?
        puts "    #{b}: #{bucket_tally[b]}"
      end
    end
    if unpaired_tally[:clones_with_unpaired_tiles].positive?
      puts
      puts "  #{unpaired_tally[:clones_with_unpaired_tiles]} clone(s) had tiles that could not be"
      puts "  paired by a unique label; their field attribution is partial."
    end
    puts
    puts "  Sample:"
    examples.each do |e|
      puts "    child_board=#{e[:cb]} clone=#{e[:clone]} source=#{e[:source]} " \
           "bucket=#{e[:bucket]} unpaired=#{e[:unpaired]} " \
           "fields=#{e[:fields].join(',').presence || '-'} shape=#{e[:shape].join(',').presence || '-'}"
    end
    puts
    puts "  Reading this:"
    puts "    structural / content_edit — a person changed something. Never consolidate."
    puts "    art_only — the clone differs ONLY in which picture each tile froze."
    puts "      Not a user edit, but consolidating still CHANGES THE PICTURES on a"
    puts "      communicator's board, which for an AAC user is a real disruption."
    puts "      The app's own rule is pull-not-push (update_to_default_docs), so"
    puts "      these are reported, not auto-migrated."
  end
end
