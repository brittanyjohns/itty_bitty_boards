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

  # The video counterpart of refresh_listing_images. Rendering one is up to ten
  # Grover frames plus an ffmpeg encode, so this enqueues rather than renders —
  # same reason, one more zero on the clock.
  #
  # Selects on #listing_video_current?, which covers both "has no video" and
  # "has one rendered from a different version of this printable". A
  # hand-uploaded clip reports current and is correctly skipped: nothing here
  # could re-render it, and replacing it is exactly what an operator did NOT
  # ask for.
  #
  # PUBLISHED_ONLY=1 narrows to printables already attached to a listing — the
  # backlog you work through when the video slot arrives after the listings did.
  desc "Render the listing video for printables that have none, or a stale one"
  task render_listing_videos: :environment do
    unless VideoTranscoder.available?
      # Said out loud rather than enqueued: the job checks too and would return
      # immediately, which looks exactly like the task having worked.
      abort("ffmpeg isn't available on this host, so no listing video can be rendered here.")
    end

    scope = BoardPrintable.where(status: "complete")
    if ENV["PUBLISHED_ONLY"] == "1"
      scope = scope.where(id: BoardPrintableListing.reached_etsy.select(:board_printable_id))
    end
    pending = scope.reject(&:listing_video_current?)

    if pending.empty?
      puts "Nothing to do: every printable in scope already has a current listing video."
      next
    end

    puts "Enqueuing #{pending.size} printable(s):"
    pending.each do |printable|
      state = printable.listing_video? ? "stale" : "none"
      puts "  ##{printable.id} #{printable.board&.name.inspect} (video: #{state})"
      RenderBoardPrintableListingVideoJob.perform_async(printable.id)
    end
    puts "Done. Watch Sidekiq; each one is minutes, not seconds."
  end

  # Exports a printable's listing so `speakanyway-printables` can push it to an
  # EXISTING Etsy listing.
  #
  #   rake 'printables:export_listing[123]'   # one printable
  #   rake printables:export_listing          # every printable attached to a listing
  #
  # Why an export rather than doing it from Rails: replacing a live listing's
  # photos means DELETING the ones already on it, and Etsy::Client implements no
  # delete — deliberately, because a delete against a live listing is what the
  # drafts-only invariant exists to keep out. That repo's `etsy update
  # --replace-images` already owns and tests that path; it just needs the files
  # on disk and a config, which is all this writes.
  #
  # Two things are deliberately ABSENT from the config, and adding either would
  # be a behaviour change, not a convenience:
  #
  #   state       — omitted so the CLI leaves the listing's state alone. Writing
  #                 "active" here would be this app activating a listing.
  #   files       — omitted so --replace-files can't be used against an export
  #                 that never intended it. The download PDFs are not what this
  #                 backfill is fixing, and replacing them deletes the buyer's
  #                 files first.
  #
  # Read-only: nothing here writes to the database or to Etsy.
  desc "Export a printable's listing copy + gallery images for the printables Etsy CLI"
  task :export_listing, [:printable_id] => :environment do |_t, args|
    out_root = Pathname.new(ENV["OUT_DIR"].presence || Rails.root.join("tmp", "etsy_exports").to_s)

    # One export per LISTING, not per printable: each listing has its own copy,
    # its own gallery selection and its own Etsy id, so a printable carrying a
    # standalone and a bundle needs two folders and two CLI lines.
    listings =
      if args[:printable_id].present?
        BoardPrintable.find(args[:printable_id]).etsy_listings.select(&:attached?)
      else
        BoardPrintableListing
          .where(board_printable_id: BoardPrintable.where(status: "complete").select(:id))
          .order(:board_printable_id, :id)
          .select(&:attached?)
      end

    if listings.empty?
      puts "Nothing to export."
      next
    end

    exported = []
    listings.each do |listing|
      printable = listing.board_printable
      label = "##{printable.id} #{printable.board&.name.inspect} → listing #{listing.etsy_listing_id}"

      # Refused rather than warned: the whole point of the export is to replace
      # a live listing's photos, and a partial gallery would delete nine good
      # images and put five back.
      unless listing.listing_images_current?
        puts "  SKIP #{label} — gallery isn't current. Run printables:refresh_listing_images and wait for Sidekiq."
        next
      end

      copy = listing.resolved_copy
      if copy["title"].blank? || copy["description"].blank?
        puts "  SKIP #{label} — listing copy has no title or description."
        next
      end

      dir = out_root.join(printable.id.to_s, listing.etsy_listing_id.to_s)
      FileUtils.mkdir_p(dir)

      # Written in LISTING_IMAGE_ORDER: the CLI uploads the array in order and
      # ranks them 1..N, and rank 1 is Etsy's search thumbnail. The numeric
      # filename prefix is for the human reviewing the folder — the ORDER of the
      # array is what actually decides the ranks.
      image_names = listing.image_files.each_with_index.map do |file, index|
        name = format("%02d-%s.png", index + 1, file.metadata["variant"].to_s.dasherize)
        File.binwrite(dir.join(name), file.download)
        name
      end

      config = {
        "title" => copy["title"],
        "description" => copy["description"],
        "price" => (copy["price_cents"].to_i / 100.0).round(2),
        "tags" => Array(copy["tags"]),
        "images" => image_names,
      }
      File.write(dir.join("listing.json"), JSON.pretty_generate(config) + "\n")

      puts "  #{label} → #{dir} (#{image_names.size} images, #{config['tags'].size} tags)"
      exported << [listing, dir]
    end

    if exported.empty?
      puts "Nothing exported."
      next
    end

    puts
    puts "Review the tags in each listing.json, then from the speakanyway-printables repo:"
    exported.each do |listing, dir|
      puts "  npm run etsy -- update #{listing.etsy_listing_id} #{dir}/listing.json --replace-images"
    end
    puts
    puts "Do ONE first and check it in the seller UI: --replace-images deletes the listing's existing"
    puts "photos before uploading these. The listing VIDEO is a separate slot and is untouched by this."
  end

  desc "List every Etsy listing made from a printable — the shop reconciliation view"
  task listings: :environment do
    rows = BoardPrintableListing.includes(board_printable: :board).order(:board_printable_id, :id)

    if rows.empty?
      puts "No listings yet."
      next
    end

    rows.each do |listing|
      printable = listing.board_printable
      puts format(
        "  printable #%-6s %-30s listing %-12s %-11s %-10s %s",
        printable.id,
        (printable.board&.name || "Board ##{printable.board_id}").truncate(30),
        listing.etsy_listing_id || "—",
        listing.state,
        listing.purpose,
        listing.label,
      )
    end

    puts
    puts "#{rows.size} listing(s). Compare against the shop: this app cannot read Etsy back, so a"
    puts "draft deleted there still shows here, and a draft made there is invisible to this."
  end

  desc "Unstick a listing row wedged in `publishing` (CONFIRMED_SHOP_CHECKED=1 required)"
  task :reset_stuck_listing, [:listing_id] => :environment do |_t, args|
    listing = BoardPrintableListing.find(args[:listing_id])

    puts "  printable ##{listing.board_printable_id}, listing row ##{listing.id}"
    puts "  state:        #{listing.state}"
    puts "  claimed at:   #{listing.claimed_at || "—"}"
    puts "  etsy listing: #{listing.etsy_listing_id || "—"}"
    puts

    unless listing.state == "publishing"
      abort("That row isn't stuck — it's #{listing.state}. Nothing to reset.")
    end

    # Deliberately gated rather than automatic. A row stuck in `publishing`
    # means a job was dispatched against a REAL shop and this app does not know
    # what it did; resetting it on a timer is a duplicate-draft generator, and
    # the app implements no call that could read the listing back and check.
    unless ENV["CONFIRMED_SHOP_CHECKED"] == "1"
      abort(
        "Open the Etsy seller UI and check whether a draft was created for this printable first.\n" \
        "If one WAS created, do not reset — record its id by hand instead, or you will publish twice.\n" \
        "If none was, re-run with CONFIRMED_SHOP_CHECKED=1.",
      )
    end

    listing.update!(state: "failed", error: "Publish was reset by hand after the shop was checked.")
    puts "Reset to `failed`. \"Retry Etsy draft\" on its card will publish it."
  end
end
