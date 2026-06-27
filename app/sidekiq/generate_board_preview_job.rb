class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

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
    return if board.settings.is_a?(Hash) && board.settings["builder_child"]

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
