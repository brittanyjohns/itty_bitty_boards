class GenerateBoardPrintableJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  def perform(board_printable_id)
    printable = BoardPrintable.find_by(id: board_printable_id)
    return unless printable

    Boards::Printables::Generate.new(printable: printable).call
  end
end
