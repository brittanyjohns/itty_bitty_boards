class GenerateImageJob
  include Sidekiq::Job

  def perform(image_id)
    puts "**** GenerateImageJob - perform **** \n"

    image = Image.find(image_id)
    image.create_image_doc
    # Do something
  end
end
