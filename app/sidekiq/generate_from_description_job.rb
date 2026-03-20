class GenerateFromDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false, backtrace: true

  def perform(menu_id, board_id = nil, screen_size = nil)
    menu = Menu.find(menu_id)
    board = Board.find(board_id)
    unless board
      Rails.logger.error "No board found for Menu #{menu.id} - #{menu.name}"
      return nil
    end

    begin
      Rails.logger.info "Generating images for board: #{board_id} from description: #{menu.description}"
      board.update_column(:status, "generating_images")
      menu.create_images_from_description(board)
      board.update_column(:status, "processing")
      board.reset_layouts
      GenerateBoardPreviewJob.perform_async(board.id, "lg", false, true, false)
      # GenerateBoardPreviewJob.perform_in(2.minute, board.id, "lg", false, true, true)
      board.update_column(:status, "complete")
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}"
      if board
        board.update_column(:status, "failed")
      end
    end
  end
end
