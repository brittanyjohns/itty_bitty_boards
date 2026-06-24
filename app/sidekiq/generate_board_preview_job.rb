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
