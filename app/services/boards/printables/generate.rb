# Orchestrates the three printable stages — collect board pages, render the
# wrapper pages, merge — then attaches the results and stamps the record.
#
# Everything here is Grover work, so it only ever runs on Sidekiq, never on a
# request thread: the configured Grover timeout is enormous and a 25-board
# bundle is 50 Chrome renders.
module Boards
  module Printables
    class Generate
      def initialize(printable:)
        @printable = printable
      end

      def call
        printable.mark_generating!

        collected = CollectPages.new(
          board: printable.board,
          include_subboards: printable.include_subboards,
          max_boards: printable.max_boards,
        ).call

        wrappers = RenderWrappers.new(
          board: printable.board,
          board_count: collected[:boards].length,
          topic: printable.topic,
        ).call

        files = MergePdf.new(
          wrappers: wrappers,
          pages: collected[:pages],
          boards: collected[:boards],
          slug: printable.board.slug.presence || "board-#{printable.board.id}",
        ).call

        blobs = files.map do |file|
          printable.attach_pdf!(filename: file.filename, bytes: file.bytes, variant: file.variant)
        end

        # A re-run of the same record can produce different filenames (renamed
        # board) or a different variant set (a subboard added since last time),
        # so anything not written by THIS run is a stale download.
        printable.purge_stale_pdfs!(blobs.map(&:key))

        printable.update!(
          status: "complete",
          page_count: files.sum(&:page_count),
          board_ids: collected[:boards].map(&:id),
          error_message: nil,
        )

        printable
      rescue => e
        # Record the failure for the admin UI, then re-raise so Sidekiq's
        # retry still applies — a transient Chrome/S3 blip should get another
        # attempt, not be swallowed into a permanent "failed".
        printable.mark_failed!(e.message)
        raise
      end

      private

      attr_reader :printable
    end
  end
end
