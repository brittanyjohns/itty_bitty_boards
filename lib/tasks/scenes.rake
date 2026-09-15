namespace :scenes do
  desc "Import the vendored TabletScene/PaperScene mockups as single-slot scene templates. " \
       "Idempotent; FORCE=1 re-syncs name and slots of existing ones."
  task import_vendored: :environment do
    result = Scenes::ImportVendored.call(force: ENV["FORCE"] == "1")

    puts "Created:   #{result.created.size} #{result.created.join(", ")}"
    puts "Updated:   #{result.updated.size} #{result.updated.join(", ")}"
    puts "Unchanged: #{result.unchanged.size}"
    puts "Skipped (JPG missing): #{result.skipped.join(", ")}" if result.skipped.any?
  end
end
