# Renders the styled 4:3 gallery slides for a printable. A handful of Grover
# renders — the slides plus three passes of page thumbnails — so it never runs
# on a request thread.
class RenderBoardPrintableStyledSlidesJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(board_printable_id)
    printable = BoardPrintable.find_by(id: board_printable_id)
    return unless printable&.complete?

    Boards::Printables::RenderStyledSlides.new(printable: printable).call
  end
end
