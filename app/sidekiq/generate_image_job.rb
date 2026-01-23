class GenerateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 3, backtrace: true

  def perform(image_id, user_id = nil, image_prompt = nil, board_id = nil, screen_size = nil, transparent_bg = false)
    image = Image.find(image_id)

    board_image = nil
    if image_prompt
      image.temp_prompt = image_prompt
    end
    board_image = BoardImage.find_by(board_id: board_id, image_id: image_id) if board_id
    if board_image
      board_image.update(status: "generating")
    end
    begin
      Rails.logger.info "Generating image for user: #{user_id}, image: #{image_id}, prompt: #{image.temp_prompt}"
      if transparent_bg
        prompt_with_bg = "#{image.temp_prompt} with a transparent background"
        image.image_prompt = prompt_with_bg
      else
        image.image_prompt = image.temp_prompt
      end
      new_doc = image.create_image_doc(user_id)
      new_doc.update(source_type: "OpenAI")
      if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
        image.image_prompt = image.image_prompt.gsub(Menu::PROMPT_ADDITION, "")
        image.save!
      end
      Rails.logger.info "Generated image for user: #{user_id}, image: #{image_id}, url: #{new_doc.display_url}"
      if board_image
        Rails.logger.info "Updating board image for board: #{board_id}, image: #{image_id}, url: #{new_doc.display_url}"
        board_image.update(status: "complete", display_image_url: new_doc.display_url)
      end
      # if board_id
      #   board = Board.find(board_id)
      #   board.calculate_grid_layout_for_screen_size(screen_size || "lg") if board
      # end
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}"
      image.update(status: "error", error: e.message)
      board_image.update(status: "error") if board_image
    end
  end
end
