class EnhanceImageDescriptionJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(menu_id)
    puts "**** EnhanceImageDescriptionJob - perform **** \n"

    menu = Menu.find(menu_id)
    menu.enhance_image_description
    puts "**** EnhanceImageDescriptionJob - perform - done **** \n"
  end
    
end
