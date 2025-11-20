class EditBoardImageJob
  include Sidekiq::Job

  def perform(board_image_id, prompt, transparent_bg = false)
    Rails.logger.info "Starting EditBoardImageJob for BoardImage ID #{board_image_id} with prompt: #{prompt}, transparent_bg: #{transparent_bg}"
    board_image = BoardImage.find_by(id: board_image_id)
    if board_image.blank?
      Rails.logger.error "BoardImage not found with id: #{board_image_id}"
      return
    end
    puts "Creating image edit for BoardImage ID #{board_image_id} with prompt: #{prompt}, transparent_bg: #{transparent_bg}"
    board_image.create_image_edit!(prompt, transparent_bg)
  rescue => e
    Rails.logger.error "Error in EditBoardImageJob for BoardImage ID #{board_image_id}: #{e.message}"
    raise e
  ensure
    board_image.update(status: "edited") if board_image.present?
  end
end
