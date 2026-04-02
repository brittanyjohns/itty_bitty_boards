class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :default

  def perform(board_id, options = {})
    # screen_size = "lg", hide_colors = false, hide_header = false, generate_pdf = false, generate_png = true
    screen_size = options["screen_size"] || options["screenSize"] || "lg"
    hide_colors = options["hide_colors"] || options["hideColors"] || false
    hide_header = options["hide_header"] || options["hideHeader"] || false
    generate_pdf = options["generate_pdf"] || options["generatePdf"] || false
    generate_png = options["generate_png"] || options["generatePng"] || false

    board = Board.find(board_id)
    original_preview_image_url = board.preview_image_url

    Boards::GeneratePreviewAssets.new(
      board: board,
      screen_size: screen_size,
      hide_colors: hide_colors,
      hide_header: hide_header,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: generate_png, generate_pdf: generate_pdf)

    board.reload
    if board.preview_image.attached?
      preview_image_url = board.preview_image_url
      board.update_preset_display_image_url(preview_image_url)
      board.update_column(:display_image_url, preview_image_url) if board.user_id.nil?
      result = Board.where(display_image_url: original_preview_image_url).update_all(display_image_url: preview_image_url)
      if result > 0
        Rails.logger.debug "Updated display_image_url for #{result} boards to new preview image URL for board #{board_id} to new url: #{preview_image_url}"
      end
    end
  end
end
