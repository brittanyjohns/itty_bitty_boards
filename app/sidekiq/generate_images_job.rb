class GenerateImagesJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 1, backtrace: true

  def perform(image_ids, board_id = nil, transparent_bg = false)
    # image = Image.find(image_id)
    images = Image.where(id: image_ids)
    board = Board.find_by(id: board_id) if board_id
    return if images.empty?

    begin
      board.update_column(:status, "generating") if board
      images.each do |image|
        image_id = image.id
        user_id = image.user_id
        image_prompt = image.default_image_prompt
        board_image = board.board_images.find_by(image_id: image_id) if board
        if board_image
          board_image.update_column(:status, "generating")
        end
        new_doc = image.create_image_doc(user_id)
        unless new_doc
          Rails.logger.error "Failed to create image doc for image #{image_id}"
          next
        end
        new_doc.update(source_type: "OpenAI")
        if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
          image.image_prompt = image.image_prompt.gsub(Menu::PROMPT_ADDITION, "")
          image.save
        end
        if board_image
          board_image.update_column(:status, "complete")
          board_image.update_column(:display_image_url, new_doc.display_url)
        end
      end
      Rails.logger.info "Completed generating images for board: #{board_id}, image_ids: #{image_ids.join(", ")}"
      board.update_column(:status, "complete") if board
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}"
      image.update_column(:status, "failed")
      board_image.update_column(:status, "failed") if board_image
      board.update_column(:status, "failed") if board
    end
  end
end
