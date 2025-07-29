class GenerateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  def perform(image_id, user_id = nil, image_prompt = nil, board_id = nil, screen_size = nil)
    image = Image.find(image_id)
    user = User.find(user_id) if user_id
    if user.nil?
      user = User.find_by(id: User::DEFAULT_ADMIN_ID)
      user_id = User::DEFAULT_ADMIN_ID
      unless user
        puts "**** ERROR **** \nUser with ID #{user_id} not found. Using default admin user."
        return
      end
    end
    board_image = nil
    if image_prompt
      image.temp_prompt = image_prompt
    end
    admin_image_present = image.docs.any? { |doc| doc.user_id == User::DEFAULT_ADMIN_ID }
    user_image_present = image.docs.any? { |doc| doc.user_id == user.id }
    board_image = BoardImage.find_by(board_id: board_id, image_id: image_id) if board_id
    if board_image
      board_image.update(status: "generating")
    end
    begin
      new_doc = image.create_image_doc(user_id) unless admin_image_present || user_image_present
      if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
        image.image_prompt = image.image_prompt.gsub(Menu::PROMPT_ADDITION, "")
        image.save!
      end
      if board_image
        board_image.update(status: "complete", display_image_url: new_doc.display_url)
      end
      if board_id
        board = Board.find(board_id)
        board.calculate_grid_layout_for_screen_size(screen_size || "lg") if board
      end
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      image.update(status: "error", error: e.message)
      board_image.update(status: "error") if board_image

      puts "UPDATE IMAGE: #{image.inspect}"
    end
    # Do something
  end
end
