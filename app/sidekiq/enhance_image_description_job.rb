class EnhanceImageDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id, board_id=nil)
    menu = Menu.find(menu_id)
    menu.enhance_image_description(board_id)
  end
    
end
