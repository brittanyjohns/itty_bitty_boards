# Renders the marketplace listing video for a printable — up to ten Grover
# frames plus an ffmpeg encode, so it never runs on a request thread.
#
# Kept separate from RenderBoardPrintableListingImagesJob even though the two
# share a page-thumbnail pass. Merging would save a handful of Grover renders
# and would drag an ffmpeg encode along on every "Regenerate listing images"
# click, which is the fast button an admin actually uses. If that ever matters,
# the fix is a memoized collaborator both orchestrators take — not a merge.
#
# retry: 1, not the images job's 2: an ffmpeg failure is rarely transient and
# every attempt is minutes of headless Chrome.
class RenderBoardPrintableListingVideoJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(board_printable_id)
    printable = BoardPrintable.find_by(id: board_printable_id)
    return unless printable&.complete?

    # Checked here as well as inside the renderer so a host without the
    # binaries logs one line rather than looking like a silent no-op.
    unless VideoTranscoder.available?
      Rails.logger.warn("[RenderBoardPrintableListingVideoJob] printable=#{printable.id}: ffmpeg unavailable")
      return
    end

    Boards::Printables::RenderListingVideo.new(printable: printable).call
  end
end
