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
        puts "Created next words for #{record_type} id: #{image.id}"
      rescue => e
        puts "\n**** SIDEKIQ - SetNextWordsJob \n\nERROR **** \n#{e.message}\n"
      end
    end
    puts "\n\nSetNextWordsJob.perform_async(#{image_ids})\n\n"
  end
end
