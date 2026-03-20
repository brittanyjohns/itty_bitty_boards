class GenerateMenuBoardJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id, screen_size = nil)
    menu = Menu.find(menu_id)

    board = menu.boards.new(user: menu.user, name: menu.name, token_limit: menu.token_limit, predefined: menu.predefined, display_image_url: menu.menu_image_url, large_screen_columns: 10, medium_screen_columns: 6, small_screen_columns: 4, board_type: "menu", parent_id: menu.id, parent_type: "Menu")
    board.generate_unique_slug
    board.status = "pending"

    if board.save
      Rails.logger.debug "Board #{board.id} updated with menu image URL for Menu #{menu.id} - #{menu.name}: #{board.display_image_url}"
    else
      Rails.logger.error "Failed to update board #{board.id} with menu image URL for Menu #{menu.id} - #{menu.name}: #{board.display_image_url} - Errors: #{board.errors.full_messages.join(", ")}"
    end

    board.update_column(:status, "generating_words")
    begin
      result = menu.get_words_from_menu_image(board.id)
      Rails.logger.debug ">>>>Board id: #{board.id} - Menu image description result for menu #{menu.id} - #{menu.name}: #{result.inspect}"
      words = result.is_a?(Hash) ? result["menu_items"] : []
      Rails.logger.debug "Extracted words from menu image description for menu #{menu.id} - #{menu.name}: #{words.inspect}"
      board.update_column(:description, words)
      if !result || (result.is_a?(Hash) && result["menu_items"].blank?)
        Rails.logger.error "No menu items found in description for Menu #{menu.id} - #{menu.name}"
        board.update_column(:status, "error")
        return nil
      end
      # menu.update_column(:description, result) if result
      board.update_column(:status, "finding_images")
      menu.create_board_from_menu_image(board.id, result)
      Rails.logger.debug "Finished creating board from menu image for #{menu.name} - board.id: #{board.id} - result: #{result.inspect}"

      unless result
        Rails.logger.error "An error occurred while enhancing the image description for Menu #{menu.id} - #{menu.name}"
        board.update_column(:status, "error")
        return
      end
      board.update_column(:status, "processing")
      board.reload
      if board.images.count == 0
        Rails.logger.error "No images found for board #{board.id} after creating from menu image for Menu #{menu.id} - #{menu.name}"
        board.update_column(:status, "error")
        return
      end
      board.reset_layouts if board
      GenerateBoardPreviewJob.perform_async(board.id, "lg", false, true, false)

      GenerateBoardPreviewJob.perform_in(2.minute, board.id, "lg", false, true, true)
      board.update_column(:status, "complete")
    rescue => e
      Rails.logger.error "An error occurred while generating the menu board: #{e.message}"
      puts "**** ERROR **** \n#{e.message}\n"
      puts e.backtrace.join("\n")
    ensure
      board.update_column(:status, "complete") if board
    end
  end
end
