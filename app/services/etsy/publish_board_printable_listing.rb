# frozen_string_literal: true

# Creates an Etsy DRAFT listing for one BoardPrintableListing row: the listing
# itself, its price, its gallery images, and its download files.
#
# INVARIANT — this app creates drafts and nothing else. There is no argument,
# flag, or param that activates a listing; going live is a deliberate click in
# the Etsy seller UI, after a human has looked at the category, the photos, and
# the return policy. Etsy::Client#create_listing hardcodes `state: "draft"` and
# implements no activate call, so "publish" here means "create the draft".
#
# The SUBJECT is a listing row, not the printable. A printable can carry several
# listings — a standalone and a bundle, say — so "this printable is already on
# Etsy" is no longer a reason to refuse. What is refused is publishing the SAME
# ROW twice, and the row is what makes that checkable.
#
# Never retried automatically (see PublishBoardPrintableListingJob): a retry
# after a partial success creates a SECOND listing in a real shop. The row's
# `state` is claimed exactly once before the job is even enqueued, but that
# claim protects the ENQUEUE, not the non-transactional window between
# `create_listing` returning and the id landing in Postgres. `retry: 0` is what
# guarantees that window is entered at most once.
module Etsy
  class PublishBoardPrintableListing
    Result = Struct.new(:ok?, :listing_id, :listing_url, :error, keyword_init: true)

    def initialize(listing, client: nil)
      @listing = listing
      @printable = listing.board_printable
      @client = client
    end

    def call
      guard = guard_failure
      return failure(guard) if guard

      client.assert_known_taxonomy!(Client::DEFAULT_TAXONOMY_ID)

      render_listing_images_if_missing

      created = client.create_listing(
        title: copy["title"],
        description: copy["description"],
        price: price_dollars,
        tags: Array(copy["tags"]),
      )

      # THE ORPHAN FIX. The id is persisted the instant Etsy hands it back —
      # before the price, the images, the files or the video. The old code wrote
      # it only after every upload succeeded, so an exception in the middle left
      # a real draft in a real shop with nothing in Rails pointing at it, and no
      # way to find out which listing it was.
      listing.update!(
        etsy_listing_id: created[:listing_id],
        etsy_listing_url: created[:url],
        published_at: Time.current,
        state: "published",
        error: nil,
      )
      stamp_printable(created)

      uploaded = upload_assets(created[:listing_id])

      # AFTER the assets, and outside the rescue: the video is the one optional
      # part of a draft, and losing it must not turn a listing that exists into
      # a publish that reports failure.
      upload_video(created[:listing_id])

      # Only when they ALL landed. Leaving it nil is what #assets_incomplete?
      # reads, and it is the difference between "there is a half-built draft in
      # the shop, go look at it" and a listing that quietly ships with three of
      # its ten photos.
      listing.update_columns(assets_uploaded_at: Time.current, updated_at: Time.current) if uploaded

      Result.new(ok?: true, listing_id: created[:listing_id], listing_url: created[:url])
    rescue => e
      Rails.logger.error(
        "[Etsy::PublishBoardPrintableListing] listing #{listing.id}: #{e.class} - #{e.message}",
      )
      failure(e.message)
    end

    private

    attr_reader :listing, :printable

    def client = @client ||= Client.new

    # The printable's copy with this listing's overrides merged over it, so a
    # bundle can carry its own title and price while sharing everything else.
    def copy = @copy ||= listing.resolved_copy.with_indifferent_access

    def price_dollars = (copy["price_cents"].presence || ListingCopy::DEFAULT_PRICE_CENTS).to_i / 100.0

    # Everything that would make a draft wrong rather than merely unfinished.
    # Returned as a message for the admin, not raised — none of these are bugs.
    def guard_failure
      if listing.reached_etsy?
        # Scoped to the ROW. Deleting the draft on Etsy does NOT free it,
        # because nothing there writes back here; "Replace" is what allocates a
        # fresh row to publish into.
        return "This listing already has Etsy draft #{listing.etsy_listing_id}. Use \"Replace\" to " \
               "make a replacement draft — deleting it on Etsy alone won't free this row."
      end

      return "This printable isn't finished generating yet." unless printable.complete?
      return "This printable has no PDF files attached." if pdf_files.empty?
      return "Listing title and description are required." if copy["title"].blank? || copy["description"].blank?

      if pdf_files.size > Client::MAX_DOWNLOAD_FILES
        return "This listing has #{pdf_files.size} PDFs; Etsy caps a listing at " \
               "#{Client::MAX_DOWNLOAD_FILES} download files."
      end

      oversized = pdf_files.find { |f| f.byte_size > Client::FILE_CAP_BYTES }
      if oversized
        return "#{oversized.filename} is #{ActiveSupport::NumberHelper.number_to_human_size(oversized.byte_size)}; " \
               "Etsy caps a download file at 20 MB. Split it with the speakanyway-printables pipeline first."
      end

      nil
    end

    # Write-once. It is the marketplace-protection watermark — "these boards
    # have been printed and sold at least once" — so a later listing must not
    # move it. The scalar listing columns are mirrored for as long as they
    # exist, so a rollback to the release before this one still sees the draft;
    # the row is the source of truth.
    def stamp_printable(created)
      printable.update_columns(
        etsy_listing_id: created[:listing_id],
        etsy_listing_url: created[:url],
        etsy_published_at: printable.etsy_published_at || Time.current,
        etsy_error: nil,
        updated_at: Time.current,
      )
    end

    # Etsy will create a listing with no photos but won't let it go live
    # without one, so a draft with an empty gallery is a dead end. Rendering
    # here rather than refusing means one button still gets you a finishable
    # draft.
    # Guarded on "current", not "any": a printable generated before the gallery
    # was redesigned still HAS images — the retired cover/what's-included pair —
    # and publishing those would put a retired gallery design on a live listing.
    def render_listing_images_if_missing
      return if printable.listing_images_current?

      Boards::Printables::RenderListingImages.new(printable: printable).call
      printable.reload
    end

    # A failure here leaves the row `published` with its id set, because the
    # draft genuinely exists — that is the state #assets_incomplete? names, and
    # it is deliberately not retryable from the admin: re-running would upload
    # against a draft that already has some of them.
    def upload_assets(listing_id)
      client.set_listing_price(listing_id, price_dollars)
      upload_images(listing_id)
      upload_files(listing_id)
      true
    rescue StandardError => e
      Rails.logger.error(
        "[Etsy::PublishBoardPrintableListing] listing #{listing.id} assets: #{e.class} - #{e.message}",
      )
      listing.update_columns(
        error: "Draft #{listing_id} was created, but its images or files failed to upload: #{e.message}"
          .truncate(1000),
        updated_at: Time.current,
      )
      false
    end

    def image_files = printable.current_image_files

    def pdf_files = printable.pdf_files

    def upload_images(listing_id)
      image_files
        .sort_by { |f| BoardPrintable::LISTING_IMAGE_ORDER.index(f.metadata["variant"]) }
        .each_with_index do |file, index|
          client.upload_image(listing_id, bytes: file.download, filename: file.filename.to_s, rank: index + 1)
        end
    end

    def upload_files(listing_id)
      pdf_files.each_with_index do |file, index|
        client.upload_file(listing_id, bytes: file.download, filename: file.filename.to_s, rank: index + 1)
      end
    end

    # Opt-in, and never fatal.
    #
    # Deliberately NOT mirrored on #render_listing_images_if_missing. That
    # exists because Etsy won't let a listing go live with zero photos, so a
    # draft without them is a dead end. There is no equivalent rule for video —
    # a draft without one is finishable — and rendering a video here would put
    # ten Grover renders plus an ffmpeg encode inside a job that is deliberately
    # `retry: 0`, where a timeout wedges a publish half-done in a real shop. The
    # video is rendered from the admin, ahead of time.
    def upload_video(listing_id)
      file = printable.video_file
      return if file.blank?

      client.upload_video(listing_id, bytes: file.download, filename: file.filename.to_s)
      # Etsy allows one video per listing and this app can't read back whether
      # one is there, so the draft having received one has to be remembered.
      # Per ROW, because the rule is per listing.
      listing.mark_video_pushed!
    rescue StandardError => e
      Rails.logger.error(
        "[Etsy::PublishBoardPrintableListing] listing #{listing.id} video: #{e.class} - #{e.message}",
      )
      listing.update_columns(
        error: "Draft created, but the listing video failed to upload: #{e.message}".truncate(1000),
        updated_at: Time.current,
      )
    end

    # Persisted with update_columns so a failure can never disturb the record's
    # callbacks, and so the reason survives for the show page — this runs on
    # Sidekiq, where a returned message goes nowhere a human can see it.
    #
    # `failed` and not `pending`: nothing was created on Etsy, so the same
    # one-shot claim can accept a retry, but the state has to say what happened.
    def failure(message)
      listing.update_columns(
        state: listing.reached_etsy? ? listing.state : "failed",
        error: message.to_s.truncate(1000),
        updated_at: Time.current,
      )
      Result.new(ok?: false, error: message)
    end
  end
end
