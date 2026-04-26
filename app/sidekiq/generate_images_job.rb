class GenerateImagesJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 1, backtrace: true

  def perform(image_ids, board_id = nil)
    images = Image.where(id: image_ids)
    return if images.empty?

    board = Board.includes(:board_images).find_by(id: board_id) if board_id
    board_images = board&.board_images&.where(image_id: image_ids)

    board.update_column(:status, "generating") if board
    board_images.update_all(status: "generating") if board_images.present?

    failed_image_ids = []

    begin
      images.each do |image|
        board_image = board&.board_images&.find_by(image_id: image.id)

        begin
          board_image&.update_column(:status, "generating")

          user_id = image.user_id
          if board.board_type == "menu"
            image_prompt = image.default_menu_image_prompt
          else
            image_prompt = image.default_image_prompt
          end

          new_doc = image.create_image_doc(user_id, image_prompt)

          unless new_doc
            Rails.logger.error("Failed to create image doc for image #{image.id}")
            failed_image_ids << image.id
            image.update_column(:status, "failed") if image.has_attribute?(:status)
            board_image&.update_column(:status, "failed")
            next
          end

          new_doc.update(source_type: "OpenAI")

          if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
            image.update!(
              image_prompt: image.image_prompt.gsub(Menu::PROMPT_ADDITION, ""),
            )
          end

          image.update_column(:status, "complete") if image.has_attribute?(:status)
          board_image&.update_column(:status, "complete")
          board_image&.update_column(:display_image_url, new_doc.tile_url)
        rescue => e
          failed_image_ids << image.id

          Rails.logger.error(
            [
              "**** IMAGE ERROR ****",
              "Image ID: #{image.id}",
              "Board ID: #{board_id}",
              e.message,
              *e.backtrace,
            ].join("\n")
          )

          image.update_column(:status, "failed") if image.has_attribute?(:status)
          board_image&.update_column(:status, "failed")

          next
        end
      end

      Rails.logger.info(
        "Completed GenerateImagesJob for board: #{board_id}, image_ids: #{image_ids.join(", ")}, failed_image_ids: #{failed_image_ids.join(", ")}"
      )

      if board
        if failed_image_ids.empty?
          board.update_column(:status, "complete")
        else
          # Pick whichever status makes sense in your app:
          # "failed", "partial", or leave it alone.
          board.update_column(:status, "complete_with_errors")
        end
      end
    rescue => e
      Rails.logger.error(
        [
          "**** JOB ERROR ****",
          "Board ID: #{board_id}",
          e.message,
          *e.backtrace,
        ].join("\n")
      )

      board.update_column(:status, "failed") if board
      raise e
    end
  end
end
