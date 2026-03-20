class EnhanceImageDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id, board_id = nil, screen_size = nil)
    menu = Menu.find(menu_id)
    board = Board.find_by(id: board_id) if board_id
    unless board
      Rails.logger.error "No board found for Menu #{menu.id} - #{menu.name} when trying to enhance image description."
      puts "No board found for Menu #{menu.id} - #{menu.name} when trying to enhance image description."
      return nil
    end
    board.update_column(:status, "finding_images")
    begin
      result = menu.enhance_image_description(board_id)
      unless result
        Rails.logger.error "An error occurred while enhancing the image description."
      end
      board.update_column(:description, result) if result
      board.update_column(:status, "processing") if board
      board.reset_layouts if board
      Rails.logger.error "NO BOARD FOUND" unless board
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n"
      Rails.logger.error e.backtrace.join("\n")
    ensure
      board.update(status: "complete") if board
      GenerateBoardPreviewJob.perform_async(board.id, screen_size || "lg", false, true, false) if board
    end
  end
end
