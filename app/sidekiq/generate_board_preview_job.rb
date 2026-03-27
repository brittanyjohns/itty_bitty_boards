class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :default

  def perform(board_id, options = {})
    # screen_size = "lg", hide_colors = false, hide_header = false, generate_pdf = false, generate_png = true
    screen_size = options["screen_size"] || options["screenSize"] || "lg"
    hide_colors = options["hide_colors"] || options["hideColors"] || false
    hide_header = options["hide_header"] || options["hideHeader"] || false
    generate_pdf = options["generate_pdf"] || options["generatePdf"] || false
    generate_png = options["generate_png"] || options["generatePng"] || true

    board = Board.find(board_id)

    Boards::GeneratePreviewAssets.new(
      board: board,
      screen_size: screen_size,
      hide_colors: hide_colors,
      hide_header: hide_header,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: generate_png, generate_pdf: generate_pdf)

    if board.preview_image.attached?
      preview_image_url = board.preview_image_url
      board.update_preset_display_image_url(preview_image_url)
      if board.display_image_url.blank?
        board.update_column(:display_image_url, preview_image_url)
      end
    end
  end
end
