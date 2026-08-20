# Creates the Etsy draft for one BoardPrintableListing off the request thread —
# the work is a taxonomy fetch, ten Grover renders when the gallery images are
# missing, and up to five multipart uploads.
#
# retry: 0 on purpose, and the claim below is NOT a reason to relax it. Every
# other job here retries a transient blip happily, but this one writes to a real
# Etsy shop: a retry after a partial success creates a SECOND draft listing, and
# nothing downstream would notice.
#
# Two different races, two different guards:
#
#   * The ENQUEUE is gated by a compare-and-set on `state` in the controller,
#     which runs in the request thread where Postgres can order it. That is what
#     stops a double-click dispatching two jobs.
#   * The WORK is gated here. A hand-run Sidekiq retry lands after the service
#     has already moved the row off `publishing`, and stops.
#
# Neither closes the non-transactional window between `create_listing` returning
# and the id landing in Postgres. Only `retry: 0` does.
class PublishBoardPrintableListingJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(board_printable_listing_id)
    listing = BoardPrintableListing.find_by(id: board_printable_listing_id)
    return unless listing
    return unless listing.state == "publishing"

    Etsy::PublishBoardPrintableListing.new(listing).call
  end
end
