class SetNextWordsJob
  include Sidekiq::Job

  def perform(image_ids)
    Rails.logger.info "**** SIDEKIQ - SetNextWordsJob ****"
    images = Image.where(id: image_ids)
    images.each do |image|
      begin
        words = image.set_next_words!
        Rails.logger.info "**** SIDEKIQ - SetNextWordsJob - Image: #{image.id} - Words: #{words} ****"
      rescue => e
        puts "\n**** SIDEKIQ - SetNextWordsJob\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
