# frozen_string_literal: true

# Sends an already-rendered listing video to the Etsy listing a
# BoardPrintableListing is ALREADY attached to.
#
# Why this exists as its own path: Etsy::PublishBoardPrintableListing uploads it
# as part of creating a draft, and this app implements no call that updates a
# listing — so a video rendered after the draft was made could not reach it at
# all. The usual answer to that is "Detach & relist", which is right for a
# GALLERY (replacing photos needs a delete Etsy::Client deliberately doesn't
# have) but disproportionate for a video: adding one to a listing that has none
# is a plain additive POST, the same class of call as #upload_image and
# #upload_file, which already run against listings.
#
# INVARIANT — this does not weaken the drafts-only rule. It adds media; it
# sends no state, no title, no tags, and there is still no path in this app that
# activates a listing or deletes anything from one.
#
# The hazard it DOES have to hold is Etsy's one-video-per-listing rule. The app
# cannot read a listing back, so it can't discover an existing video; a second
# POST has no outcome it could verify. `board_printable_listings.video_pushed_at`
# is the local memory that makes the second one refusable, and it is stamped by
# the publish path too — a draft that was born with a video must not be offered
# another.
#
# The stamp is per ROW because Etsy's rule is per LISTING: the same rendered
# clip going to a printable's standalone listing AND its bundle listing is
# correct, and the old printable-wide stamp would have refused the second.
#
# Never retried (see PushBoardPrintableListingVideoJob), for the same reason
# publishing isn't: a retry after a partial success is a second video against a
# listing that may already have taken the first.
module Etsy
  class PushListingVideo
    Result = Struct.new(:ok?, :error, keyword_init: true)

    def initialize(listing, client: nil)
      @listing = listing
      @printable = listing.board_printable
      @client = client
    end

    def call
      guard = guard_failure
      return failure(guard) if guard

      file = listing.video_file
      client.upload_video(listing.etsy_listing_id, bytes: file.download, filename: file.filename.to_s)

      # Stamped only after Etsy accepted it. A failed upload must leave the
      # control available, or a transient error would lock the listing out of
      # ever getting its video.
      listing.mark_video_pushed!
      listing.update_columns(error: nil, updated_at: Time.current)

      Result.new(ok?: true)
    rescue StandardError => e
      Rails.logger.error("[Etsy::PushListingVideo] listing #{listing.id}: #{e.class} - #{e.message}")
      failure("The listing video failed to upload: #{e.message}")
    end

    private

    attr_reader :listing, :printable

    def client = @client ||= Client.new

    def guard_failure
      return "This listing isn't attached to an Etsy draft." unless listing.attached?
      return "This listing has no video. Render or upload one first." unless listing.listing_video?

      if listing.video_pushed_at.present?
        # Naming the way out matters, and the way out is NOT another POST from
        # here: replacing a listing's video needs Etsy's `video_id` field, which
        # is the update call this app pointedly does not implement.
        return "A video has already been sent to listing #{listing.etsy_listing_id}. Etsy allows one per " \
               "listing, and this app can't replace it — swap it in the Etsy seller UI."
      end

      nil
    end

    def failure(message)
      listing.update_columns(error: message.to_s.truncate(1000), updated_at: Time.current)
      Result.new(ok?: false, error: message)
    end
  end
end
