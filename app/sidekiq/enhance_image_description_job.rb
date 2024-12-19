class EnhanceImageDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id, board_id = nil, screen_size = nil)
    menu = Menu.find(menu_id)
    begin
      result = menu.enhance_image_description(board_id)
      unless result
        puts "An error occurred while enhancing the image description."
        raise "Invalid image description."
      end
      board = Board.find(board_id) if board_id
      board.reset_layouts if board
      puts "NO BOARD FOUND" unless board
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      puts e.backtrace.join("\n")
    end
  end
end
