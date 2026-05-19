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

    Boards::GeneratePreviewAssets.new(
      board: board,
      screen_size: screen_size,
      hide_colors: hide_colors,
      hide_header: hide_header,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: generate_png, generate_pdf: generate_pdf)

    board.reload
    board.update_preset_display_image_url(board.preview_image_url) if board.preview_image.attached?
  end
end
