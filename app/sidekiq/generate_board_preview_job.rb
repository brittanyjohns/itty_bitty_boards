class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :default

  def perform(board_id, screen_size = "lg", hide_colors = false, hide_header = false, generate_pdf = false, generate_png = true)
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
    end
  end
end
