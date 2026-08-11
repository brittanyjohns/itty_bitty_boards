# Creates the Etsy draft off the request thread — the work is a taxonomy fetch,
# two Grover renders when the gallery images are missing, and up to five
# multipart uploads.
#
# retry: 0 on purpose. Every other job here retries a transient blip happily,
# but this one writes to a real Etsy shop: a retry after a partial success
# creates a SECOND draft listing, and nothing downstream would notice. A
# failure records itself on the printable and waits for a human to look.
class PublishBoardPrintableToEtsyJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(board_printable_id)
    printable = BoardPrintable.find_by(id: board_printable_id)
    return unless printable
    # Belt and braces against a double-click enqueueing twice: the service
    # guards on this too, but checking here keeps the second job from doing any
    # work at all.
    return if printable.etsy_published?

    Etsy::PublishBoardPrintable.new(printable).call
  end
end
