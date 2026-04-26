class EnhanceImageDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id, board_id, screen_size = nil)
    menu = Menu.find(menu_id)
    board = Board.find_by(id: board_id)

    unless board
      Rails.logger.error "No board found for Menu #{menu.id} - #{menu.name} when trying to enhance image description."
      return
    end

    board.update_column(:status, "finding_images")

    begin
      result = menu.enhance_image_description(board_id)

      if result.nil?
        Rails.logger.error "An error occurred while enhancing the image description."
        board.update_column(:status, "error")
        return
      end
      result_str = result.is_a?(String) ? result : result.to_json
      Rails.logger.info "Enhanced image description result: #{result_str}"

      # board.update_column(:description, result_str)
      board.update_column(:status, "processing")
      board.reset_layouts

      board.update_column(:status, "complete")
      board.run_generate_preview_job
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n"
      Rails.logger.error e.backtrace.join("\n")
      board.update_column(:status, "complete") if board&.persisted?
    end
  end
end
