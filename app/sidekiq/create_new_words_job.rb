class CreateNewWordsJob
  include Sidekiq::Job

  def perform(image_ids)
    images = Image.where(id: image_ids)
    images.each do |image|
      begin
        image.create_words_from_next_words
      rescue => e
        puts "\n**** SIDEKIQ - CreateNewWordsJob \n\nERROR **** \n#{e.message}\n"
      end
    end
  end
end
