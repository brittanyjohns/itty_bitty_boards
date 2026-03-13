class GenerateBoardPreviewJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :ai_images

  def perform(board_id, screen_size = "lg", hide_colors = false)
    board = Board.find(board_id)

    Boards::GeneratePreviewAssets.new(
      board: board,
      screen_size: screen_size,
      hide_colors: hide_colors,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: true, generate_pdf: false)
  end
end
