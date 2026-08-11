# frozen_string_literal: true

# Creates an Etsy DRAFT listing for a finished BoardPrintable: the listing
# itself, its price, its gallery images, and its download files.
#
# INVARIANT — this app creates drafts and nothing else. There is no argument,
# flag, or param that activates a listing; going live is a deliberate click in
# the Etsy seller UI, after a human has looked at the category, the photos, and
# the return policy. Etsy::Client#create_listing hardcodes `state: "draft"` and
# implements no activate call, so "publish" here means "create the draft".
#
# Never retried automatically (see PublishBoardPrintableToEtsyJob): a retry
# after a partial success creates a SECOND listing in a real shop. A failure
# leaves whatever was created in place, records the error, and waits for a
# human — a half-built draft is easy to delete, a duplicate is easy to miss.
module Etsy
  class PublishBoardPrintable
    Result = Struct.new(:ok?, :listing_id, :listing_url, :error, keyword_init: true)

    def initialize(printable, client: nil)
      @printable = printable
      @client = client
    end

    def call
      guard = guard_failure
      return failure(guard) if guard

      client.assert_known_taxonomy!(Client::DEFAULT_TAXONOMY_ID)

      render_listing_images_if_missing

      listing = client.create_listing(
        title: copy["title"],
        description: copy["description"],
        price: price_dollars,
        tags: Array(copy["tags"]),
      )

      # Etsy accepts a price on create but the inventory endpoint is the only
      # writer that reliably sticks, so it is set again explicitly rather than
      # trusted from the create call.
      client.set_listing_price(listing[:listing_id], price_dollars)

      upload_images(listing[:listing_id])
      upload_files(listing[:listing_id])

      printable.update!(
        etsy_listing_id: listing[:listing_id],
        etsy_listing_url: listing[:url],
        etsy_published_at: Time.current,
        etsy_error: nil,
      )

      Result.new(ok?: true, listing_id: listing[:listing_id], listing_url: listing[:url])
    rescue => e
      Rails.logger.error("[Etsy::PublishBoardPrintable] printable #{printable.id}: #{e.class} - #{e.message}")
      failure(e.message)
    end

    private

    attr_reader :printable

    def client = @client ||= Client.new

    def copy = @copy ||= printable.listing_copy_or_default.with_indifferent_access

    def price_dollars = (copy["price_cents"].presence || ListingCopy::DEFAULT_PRICE_CENTS).to_i / 100.0

    # Everything that would make a draft wrong rather than merely unfinished.
    # Returned as a message for the admin, not raised — none of these are bugs.
    def guard_failure
      return "This printable isn't finished generating yet." unless printable.complete?
      return "This printable has no PDF files attached." if printable.pdf_files.empty?

      if printable.etsy_published?
        return "Already on Etsy as listing #{printable.etsy_listing_id}. Delete that draft first if you want a new one."
      end

      return "Listing title and description are required." if copy["title"].blank? || copy["description"].blank?

      oversized = printable.pdf_files.find { |f| f.byte_size > Client::FILE_CAP_BYTES }
      if oversized
        return "#{oversized.filename} is #{ActiveSupport::NumberHelper.number_to_human_size(oversized.byte_size)}; " \
               "Etsy caps a download file at 20 MB. Split it with the speakanyway-printables pipeline first."
      end

      nil
    end

    # Etsy will create a listing with no photos but won't let it go live
    # without one, so a draft with an empty gallery is a dead end. Rendering
    # here rather than refusing means one button still gets you a finishable
    # draft.
    def render_listing_images_if_missing
      return if printable.listing_images?

      Boards::Printables::RenderListingImages.new(printable: printable).call
      printable.reload
    end

    def upload_images(listing_id)
      printable.image_files
               .sort_by { |f| BoardPrintable::LISTING_IMAGE_ORDER.index(f.metadata["variant"]) || 99 }
               .each_with_index do |file, index|
        client.upload_image(
          listing_id,
          bytes: file.download,
          filename: file.filename.to_s,
          rank: index + 1,
        )
      end
    end

    def upload_files(listing_id)
      printable.pdf_files.each_with_index do |file, index|
        client.upload_file(
          listing_id,
          bytes: file.download,
          filename: file.filename.to_s,
          rank: index + 1,
        )
      end
    end

    # Persisted with update_columns so a failure can never disturb `status` or
    # fire the record's callbacks — and so the reason survives for the show
    # page, which is the only place anyone will look. This runs on Sidekiq, so
    # returning the message alone would put it nowhere a human can see it.
    def failure(message)
      printable.update_columns(etsy_error: message.to_s.truncate(1000), updated_at: Time.current)
      Result.new(ok?: false, error: message)
    end
  end
end
