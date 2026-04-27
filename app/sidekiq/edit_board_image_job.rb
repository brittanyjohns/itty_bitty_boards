class EditBoardImageJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 0

  def perform(board_image_id, prompt, transparent_bg = false)
    board_image = BoardImage.find_by(id: board_image_id)
    if board_image.blank?
      Rails.logger.error "BoardImage not found with id: #{board_image_id}"
      return
    end
    board_image.create_image_edit!(prompt, transparent_bg)
  rescue => e
    Rails.logger.error "Error in EditBoardImageJob for BoardImage ID #{board_image_id}: #{e.message}"
    board_image.update(status: "error") if board_image.present?
    raise e
  ensure
    board_image.update(status: "edited") if board_image.present?
  end
end
