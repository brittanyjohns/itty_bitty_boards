# lib/tasks/vocab_sets.rake
#
# Seeds the Board Builder's "robust vocabulary set" templates (Core 60, Core 84)
# from the authored OBF/OBZ source in db/seeds/board_builder_sets/<slug>/.
# Logic lives in the autoloaded VocabSets service; these are thin wrappers.
#
#   bin/rails vocab_sets:seed                 # seed every authored slug
#   bin/rails vocab_sets:seed SLUGS=core-60   # seed only the named slug(s)
#   DRY_RUN=1 bin/rails vocab_sets:seed       # report only, no DB writes
#   bin/rails 'vocab_sets:build[core-60]'     # emit a distributable .obz to tmp/
#
# Idempotent: re-running upserts the same boards (Board.from_obf matches by
# (user_id, obf_id)) and re-applies the markers — no duplicate sets.
namespace :vocab_sets do
  desc "Seed robust vocabulary sets (Core 60/84) as predefined Board Builder templates"
  task seed: :environment do
    dry_run = ENV["DRY_RUN"].present?
    slugs = VocabSets.available_slugs(ENV["SLUGS"])

    if slugs.empty?
      puts "[vocab_sets:seed] No authored sets found under #{VocabSets::SETS_DIR} (SLUGS=#{ENV["SLUGS"].inspect})"
      next
    end

    puts "[vocab_sets:seed] #{dry_run ? "DRY RUN — " : ""}seeding: #{slugs.join(", ")}"

    slugs.each do |slug|
      if dry_run
        existing = Boards::RobustSets.find_root(slug)
        puts "  - #{slug}: would #{existing ? "update existing root ##{existing.id}" : "create new set"}"
        next
      end

      root = VocabSets.seed_slug!(slug)
      puts "  - #{slug}: root ##{root.id} \"#{root.name}\" (#{root.board_images.count} core tiles)"
    rescue StandardError => e
      warn "  - #{slug}: FAILED — #{e.class}: #{e.message}"
    end

    puts "[vocab_sets:seed] done"

    unless dry_run
      puts "[vocab_sets:seed] Also seeding standalone fringe templates..."
      Rake::Task["fringe_templates:seed"].invoke
    end
  end

  desc "Emit a distributable .obz for a slug to tmp/<slug>.obz"
  task :build, [:slug] => :environment do |_t, args|
    slug = args[:slug] or abort "usage: bin/rails 'vocab_sets:build[core-60]'"
    out = Rails.root.join("tmp", "#{slug}.obz")
    FileUtils.mkdir_p(out.dirname)
    File.binwrite(out, VocabSets.obz_bytes(slug))
    puts "[vocab_sets:build] wrote #{out} (#{File.size(out)} bytes)"
  end
end
