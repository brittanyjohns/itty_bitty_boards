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
            # Fresh menu-item images carry a description-driven prompt set at
            # creation (Menu#create_images_from_description) — keep it. Reused
            # or legacy images fall back to the label-based default.
            unless image.menu? && image.image_prompt.present?
              image.image_prompt = image.default_menu_image_prompt(board.name)
            end
          else
            image.image_prompt = image.default_image_prompt
          end
          image.save! if image.changed?
          Rails.logger.debug "BOARD TYPE: #{board.board_type} - Generating image for Image ID #{image.id} with prompt: #{image.image_prompt}"

          new_doc = image.create_image_doc(user_id, image.image_prompt)

          unless new_doc
            Rails.logger.error("Failed to create image doc for image #{image.id}")
            failed_image_ids << image.id
            image.update_column(:status, "failed") if image.has_attribute?(:status)
            board_image&.update_column(:status, "failed")
            refund_menu_image_credit(board, image.id)
            next
          end

          new_doc.update(source_type: "OpenAI")

          # if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
          #   image.update!(
          #     image_prompt: image.image_prompt.gsub(Menu::PROMPT_ADDITION, ""),
          #   )
          # end

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
          refund_menu_image_credit(board, image.id)

          next
        end
      end

      Rails.logger.debug(
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

  private

  # Menu boards pre-pay per generated image (board.settings["menu_credit"]);
  # give one image's cost back when its generation failed. Idempotent inside
  # the refund service, so the Sidekiq retry can't double-refund. No-op for
  # non-menu boards and admin builds (no reservation stashed).
  def refund_menu_image_credit(board, image_id)
    return unless board&.board_type == "menu"
    Menus::CreditRefunds.refund_failed_image!(board, image_id)
  end
end
