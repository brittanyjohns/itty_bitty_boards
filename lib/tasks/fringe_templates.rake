namespace :fringe_templates do
  desc "Seed standalone fringe page templates from db/seeds/board_builder_sets/fringe-pages/"
  task seed: :environment do
    dir = Boards::FringeTemplates::SEED_DIR
    unless dir.exist?
      puts "[fringe_templates:seed] No seed directory at #{dir}"
      next
    end

    obf_files = Dir.glob(dir.join("*.obf")).sort
    if obf_files.empty?
      puts "[fringe_templates:seed] No .obf files in #{dir}"
      next
    end

    puts "[fringe_templates:seed] Seeding #{obf_files.size} fringe templates..."
    obf_files.each do |path|
      board = Boards::FringeTemplates.seed_obf!(path)
      if board
        puts "  - #{board.name}: board ##{board.id} (#{board.board_images.count} tiles)"
      else
        warn "  - #{File.basename(path)}: no board returned"
      end
    rescue StandardError => e
      warn "  - #{File.basename(path)}: FAILED — #{e.class}: #{e.message}"
    end

    puts "[fringe_templates:seed] done"
  end
end
