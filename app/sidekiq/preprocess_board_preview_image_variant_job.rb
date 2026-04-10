class PreprocessBoardPreviewImageVariantJob
  include Sidekiq::Job
  sidekiq_options queue: :varients, retry: 2

  def perform(board_id)
    board = Board.includes(preview_image_attachment: :blob).find_by(id: board_id)
    return unless board&.preview_image&.attached?
    return unless board.preview_image.variable?
    return if board.preview_image_variant_processed?

    board.preview_image_variant.processed
    Rails.logger.info("[preview-image-variant] processed Board #{board.id}")
  rescue => e
    Rails.logger.error("[preview-image-variant] failed for Board #{board.id}: #{e.message}")
    raise e
  end
end
