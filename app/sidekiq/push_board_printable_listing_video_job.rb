# Sends a rendered listing video to the Etsy draft one BoardPrintableListing is
# already attached to. Off the request thread because the work is downloading up
# to 100 MB from S3 and posting it back out as multipart.
#
# retry: 0, for the same reason PublishBoardPrintableListingJob is: this writes
# to a real Etsy shop, and Etsy allows exactly one video per listing. A retry
# after a partial success is a second video against a listing that may already
# have taken the first, and this app has no way to read a listing back and find
# out. A failure records itself on the row and waits for a human.
class PushBoardPrintableListingVideoJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(board_printable_listing_id)
    listing = BoardPrintableListing.find_by(id: board_printable_listing_id)
    return unless listing
    # Belt and braces against a double-click enqueueing twice. The service
    # guards on this too; checking here keeps the second job from downloading
    # the clip before finding out.
    return if listing.video_pushed_at.present?

    Etsy::PushListingVideo.new(listing).call
  end
end
