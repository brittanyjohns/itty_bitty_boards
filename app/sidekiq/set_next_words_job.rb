class SetNextWordsJob
  include Sidekiq::Job

  def perform(image_ids)
    images = Image.where(id: image_ids)
    images.each do |image|
      begin
        words = image.set_next_words!
        puts "Created board from next words for image #{image.id}"
      rescue => e
        puts "\n**** SIDEKIQ - SetNextWordsJob \n\nERROR **** \n#{e.message}\n"
      end
    end
    puts "\n\nSetNextWordsJob.perform_async(#{image_ids})\n\n"
  end
end
