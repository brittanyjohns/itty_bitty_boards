class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  # A render that exhausts its retries used to vanish into the dead set, while
  # the client kept polling and eventually said "Still building your cover" —
  # advice that would never come true. Record the failure on the board so the
  # API can report it.
  sidekiq_retries_exhausted do |msg, ex|
    board_id = msg["args"]&.first
    Rails.logger.error(
      "GenerateBoardPreviewJob exhausted retries for board #{board_id}: #{ex&.class}: #{ex&.message}"
    )
    Board.find_by(id: board_id)&.mark_preview_failed!
  end

  def perform(board_id, options = {})
    screen_size = options["screen_size"] || options["screenSize"] || "lg"
    hide_colors = options["hide_colors"] || options["hideColors"] || false
    hide_header = options["hide_header"] || options["hideHeader"] || false
    generate_pdf = options["generate_pdf"] || options["generatePdf"] || false
    generate_png = options["generate_png"] || options["generatePng"] || false

    board = Board.find(board_id)

    # Board Builder sub-boards (builder_child pages — fringe/Phrases/function/
    # My Favorites/AI pages) are deliberately NOT rendered to a PNG/PDF: they're
    # represented by the folder tile that opens them, and BuildBoardSetJob writes
    # that tile's image onto the sub-board's display_image_url column. Skipping
    # the Grover render here is the single chokepoint that covers every enqueue
    # source (clone_with_images, grid/layout saves, blueprint add_image) — by the
    # time this async job runs, the builder_child flag is committed. The root
    # (builder_root) and all non-builder boards still render normally.
    #
    # `force` opts out: it marks a request that names ONE board — someone
    # clicking "Regenerate from tiles". The skip is about queue volume, not
    # about these pages being unrenderable, so a single deliberate render is
    # allowed through. Without that they could never earn a snapshot at all.
    #
    # Record the skip rather than returning silently: an unrecorded no-op is
    # indistinguishable from a slow success to anything watching, which is how
    # this button could appear to work while never doing anything.
    force = options["force"] || options["forceRender"] || false
    if !force && board.settings.is_a?(Hash) && board.settings["builder_child"]
      Rails.logger.info(
        "GenerateBoardPreviewJob skipped board #{board_id}: builder_child page — " \
        "its cover comes from the folder tile that opens it"
      )
      board.mark_preview_skipped!
      return
    end

    # GeneratePreviewAssets attaches the PNG and refreshes the preset display
    # image URL atomically, so there's no post-attach reload/write race here.
    # Any Grover/upload failure propagates and the job retries (retry: 3).
    Boards::GeneratePreviewAssets.new(
      board: board,
      screen_size: screen_size,
      hide_colors: hide_colors,
      hide_header: hide_header,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: generate_png, generate_pdf: generate_pdf)
  end
end
