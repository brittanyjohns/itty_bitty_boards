class GenerateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(image_id, user_id=nil)
    puts "**** GenerateImageJob - perform **** \n"

    image = Image.find(image_id)
    image.create_image_doc(user_id)
    # Do something
  end
end
