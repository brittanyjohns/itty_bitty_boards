class GenerateMenuBoardJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id, board_id = nil, screen_size = nil)
    menu = Menu.find(menu_id)
    board = Board.find_by(id: board_id) if board_id
    unless board
      Rails.logger.error "No board found for Menu #{menu.id} - #{menu.name} when trying to generate menu board."
      puts "No board found for Menu #{menu.id} - #{menu.name} when trying to generate menu board."
      return nil
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
        board.update_column(:status, "failed")
        return nil
      end
      # menu.update_column(:description, result) if result
      board.update_column(:status, "finding_images")
      # menu.create_board_from_menu_image(board.id, result)
      GenerateFromDescriptionJob.perform_async(menu.id, board.id, screen_size)
      Rails.logger.debug "Finished creating board from menu image for #{menu.name} - board.id: #{board.id} - result: #{result.inspect}"

      unless result
        Rails.logger.error "An error occurred while enhancing the image description for Menu #{menu.id} - #{menu.name}"
        board.update_column(:status, "failed")
        return
      end
      board.update_column(:status, "processing")
      board.reload
      if board.images.count == 0
        Rails.logger.error "No images found for board #{board.id} after creating from menu image for Menu #{menu.id} - #{menu.name}"
        board.update_column(:status, "failed")
        return
      end
      board.reset_layouts if board
      board.run_generate_preview_job if board
      failed = false
    rescue => e
      Rails.logger.error "An error occurred while generating the menu board: #{e.message}"
      puts "**** ERROR **** \n#{e.message}\n"
      puts e.backtrace.join("\n")
      failed = true
    ensure
      board.update_column(:status, failed ? "failed" : "complete") if board
    end
  end
end
