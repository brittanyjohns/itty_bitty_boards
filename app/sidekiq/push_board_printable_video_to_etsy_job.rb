# Sends a rendered listing video to the Etsy listing a printable is already
# attached to. Off the request thread because the work is downloading up to
# 100 MB from S3 and posting it back out as multipart.
#
# retry: 0, for the same reason PublishBoardPrintableToEtsyJob is: this writes
# to a real Etsy shop, and Etsy allows exactly one video per listing. A retry
# after a partial success is a second video against a listing that may already
# have taken the first, and this app has no way to read a listing back and find
# out. A failure records itself on the printable and waits for a human.
class PushBoardPrintableVideoToEtsyJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(board_printable_id)
    printable = BoardPrintable.find_by(id: board_printable_id)
    return unless printable
    # Belt and braces against a double-click enqueueing twice. The service
    # guards on this too; checking here keeps the second job from downloading
    # the clip before finding out.
    return if printable.etsy_video_pushed?

    Etsy::PushListingVideo.new(printable).call
  end
end
