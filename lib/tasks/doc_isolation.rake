# Read-only report on images whose PRIVATE docs already leaked before doc
# isolation was enforced (see the doc-isolation invariant in CLAUDE.md).
#
# A doc owned by nil or DEFAULT_ADMIN_ID is library art; any other doc is
# private to its owner. Before the fix, fallbacks could copy a private doc's URL
# into places other users read from. The code no longer does that, but URLs
# already written stay put, because both are persisted columns:
#
#   * images.src_url              — shared; every new tile snapshots it
#   * board_images.display_image_url on a board the doc's owner does NOT own
#
# This task only COUNTS and lists them. It repairs nothing: display_image_url
# is per-tile user content, and repainting a tile is destructive, so any repair
# is a separate, reviewed step.
#
#   bin/rails images:doc_isolation_report            # first 2000 images
#   LIMIT=10000 bin/rails images:doc_isolation_report
namespace :images do
  desc "Report src_urls and tiles pointing at another user's private doc (read-only)"
  task doc_isolation_report: :environment do
    limit = (ENV["LIMIT"] || 2000).to_i
    library_ids = [nil, User::DEFAULT_ADMIN_ID]

    image_ids = Doc.where(documentable_type: "Image")
      .where.not(user_id: library_ids.compact).where.not(user_id: nil)
      .distinct.limit(limit).pluck(:documentable_id)

    leaked_src = []
    leaked_tiles = []

    Image.where(id: image_ids).includes(:docs).find_each do |image|
      private_docs = image.docs.reject(&:library?)
      private_docs.each do |doc|
        url = doc.tile_url
        next if url.blank?

        # An image's src_url may hold its own owner's docs (a user's own image);
        # anyone else's doc there is a leak.
        leaked_src << [image.id, doc.id, doc.user_id] if image.src_url == url && image.user_id != doc.user_id

        BoardImage.joins(:board).where(image_id: image.id, display_image_url: url)
          .where.not(boards: { user_id: doc.user_id })
          .pluck(:id, "boards.id", "boards.user_id")
          .each { |bi_id, board_id, board_owner| leaked_tiles << [bi_id, board_id, board_owner, doc.id, doc.user_id] }
      end
    rescue => e
      puts "  image #{image.id}: skipped (#{e.class})"
    end

    nil_owned_ai = Doc.ai_generated.where(documentable_type: "Image", user_id: nil).count

    puts "Scanned #{image_ids.size} images carrying private docs (LIMIT=#{limit})"
    puts "images.src_url pointing at another user's private doc: #{leaked_src.size}"
    leaked_src.first(50).each { |i, d, u| puts "  image=#{i} doc=#{d} doc_owner=#{u}" }
    puts "tiles on a board not owned by the doc's owner:        #{leaked_tiles.size}"
    leaked_tiles.first(50).each do |bi, b, bo, d, du|
      puts "  board_image=#{bi} board=#{b} board_owner=#{bo} doc=#{d} doc_owner=#{du}"
    end
    puts "AI-generated docs with no owner (library by rule; some were minted by"
    puts "regular users' board fills before generation took the board owner): #{nil_owned_ai}"
    puts "Nothing was changed."
  end
end
