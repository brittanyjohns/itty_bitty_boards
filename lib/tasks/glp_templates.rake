namespace :glp_templates do
  desc "Seed the 6 gestalt-language (GLP) whole-phrase template boards (idempotent)"
  task seed: :environment do
    admin = Boards::GlpTemplates.default_admin
    abort "No admin user found (User::DEFAULT_ADMIN_ID=#{User::DEFAULT_ADMIN_ID})." unless admin

    puts "[glp_templates:seed] Seeding #{Boards::GlpTemplates::TEMPLATES.size} GLP template boards..."
    boards = Boards::GlpTemplates.seed!(admin: admin)
    boards.each do |board|
      puts "  - #{board.name}: board ##{board.id} (#{board.board_images.count} tiles, tags=#{board.tags.inspect})"
    end
    puts "[glp_templates:seed] done"
  end
end
