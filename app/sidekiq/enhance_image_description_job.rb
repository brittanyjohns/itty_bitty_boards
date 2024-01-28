class EnhanceImageDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id)
    menu = Menu.find(menu_id)
    menu.enhance_image_description
  end
    
end
