class SetNextWordsJob
  include Sidekiq::Job

  def perform(image_ids, record_type)
    if record_type == "Image"
      images = Image.where(id: image_ids)
    else
      images = BoardImage.where(id: image_ids)
    end
    images.each do |image|
      begin
        words = image.set_next_words!
        image.reload
        puts "Image next words: #{image.next_words}"
        if image.is_a?(BoardImage)
          puts "Creating next images for board image"
          image.create_next_images
        end
      rescue => e
        puts "\n**** SIDEKIQ - SetNextWordsJob \n\nERROR **** \n#{e.message}\n"
      end
    end
    puts "\n\nSetNextWordsJob.perform_async(#{image_ids})\n\n"
  end
end
