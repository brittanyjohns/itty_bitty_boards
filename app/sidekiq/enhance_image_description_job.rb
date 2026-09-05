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
        # The vision extraction produced nothing — the user paid for a build
        # they never got, so refund the whole spend (flat fee + image budget).
        Menus::CreditRefunds.refund_all!(board)
        return
      end
      result_str = result.is_a?(String) ? result : result.to_json
      Rails.logger.debug "Enhanced image description result: #{result_str}"

      # board.update_column(:description, result_str)
      board.update_column(:status, "processing")

      # The menu path owns this board's layout and has already finished with it:
      # Menu#create_board_from_menu_image sizes the grid to the real tile count
      # (Boards::GridFit, via #apply_grid_columns!) and packs the tiles against
      # THAT width. Our `board` was loaded before any of that, so it still holds
      # the 8/6/4 columns menus_controller#create guessed at. Re-packing here
      # would read those stale attributes (Board#get_number_of_columns reads the
      # in-memory values) and write tile x values past the board's real column
      # count — off-grid tiles that react-grid-layout clamps into the last
      # column and stacks vertically. Reload instead of re-laying-out.
      board.reload

      board.update_column(:status, "complete")
      board.run_generate_preview_job
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n"
      Rails.logger.error e.backtrace.join("\n")
      board.update_column(:status, "complete") if board&.persisted?
    end
  end
end
