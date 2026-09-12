namespace :fringe_templates do
  desc "Seed standalone fringe page templates from db/seeds/board_builder_sets/fringe-pages/"
  task seed: :environment do
    dir = Boards::FringeTemplates::SEED_DIR
    unless dir.exist?
      puts "[fringe_templates:seed] No seed directory at #{dir}"
      next
    end

    # Sources are nested one directory per core set; seed_files is the one glob
    # that knows that, shared with the admin re-seed button.
    obf_files = Boards::FringeTemplates.seed_files
    if obf_files.empty?
      puts "[fringe_templates:seed] No .obf files in #{dir}"
      next
    end

    puts "[fringe_templates:seed] Seeding #{obf_files.size} fringe templates..."
    obf_files.each do |path|
      relative = Pathname.new(path).relative_path_from(dir)
      board = Boards::FringeTemplates.seed_obf!(path)
      if board
        puts "  - #{relative}: #{board.name} board ##{board.id} (#{board.board_images.count} tiles)"
      else
        warn "  - #{relative}: no board returned"
      end
    rescue StandardError => e
      warn "  - #{relative}: FAILED — #{e.class}: #{e.message}"
    end

    puts "[fringe_templates:seed] done"
  end
end
