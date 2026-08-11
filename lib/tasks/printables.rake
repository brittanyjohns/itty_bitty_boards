namespace :printables do
  # Board printables generated before the four-slide gallery redesign still
  # carry the retired cover/what's-included pair. Publishing re-renders on its
  # own, and the admin page flags them — this is for refreshing them in bulk so
  # a listing is never one forgotten click from shipping the old art.
  #
  # A rake task rather than a data migration: the feature is admin-only, so the
  # population is tiny, and the work is Grover renders that belong on Sidekiq
  # rather than in a migration that blocks a deploy.
  desc "Re-render listing images for printables still on the retired gallery design"
  task refresh_listing_images: :environment do
    stale = BoardPrintable.where(status: "complete").reject(&:listing_images_current?)

    if stale.empty?
      puts "Nothing to do: every complete printable already has the current gallery."
      next
    end

    puts "Enqueuing #{stale.size} printable(s):"
    stale.each do |printable|
      variants = printable.image_files.map { |f| f.metadata["variant"] }.sort
      puts "  ##{printable.id} #{printable.board&.name.inspect} (has: #{variants.presence&.join(", ") || "none"})"
      RenderBoardPrintableListingImagesJob.perform_async(printable.id)
    end
    puts "Done. Watch Sidekiq; each printable is up to #{Boards::Printables::ContentTilePlan::MAX_TILES + 4} renders."
  end
end
