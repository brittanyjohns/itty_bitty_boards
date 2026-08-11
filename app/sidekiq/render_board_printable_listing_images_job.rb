# Re-renders the marketplace gallery images for a printable. Two Grover renders,
# so it never runs on a request thread.
class RenderBoardPrintableListingImagesJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(board_printable_id)
    printable = BoardPrintable.find_by(id: board_printable_id)
    return unless printable&.complete?

    Boards::Printables::RenderListingImages.new(printable: printable).call
  end
end
