class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :ai_images

  def perform(board_id, screen_size = "lg", hide_colors = false, hide_header = false)
    Rails.logger.info "Generating preview for board: #{board_id} (screen_size: #{screen_size}, hide_colors: #{hide_colors}, hide_header: #{hide_header})"
    board = Board.find(board_id)

    Boards::GeneratePreviewAssets.new(
      board: board,
      screen_size: screen_size,
      hide_colors: hide_colors,
      hide_header: hide_header,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: true, generate_pdf: false)

    if board.display_image_url.blank?
      preview_image_url = board.preview_image_url
      board.display_image_url = preview_image_url
      board.save!
    end
  end
end
