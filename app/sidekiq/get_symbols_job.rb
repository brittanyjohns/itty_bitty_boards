class GetSymbolsJob
  include Sidekiq::Job

  def perform(image_ids, number_of_symbols=5)
    image_ids.each do |image_id|
      image = Image.find(image_id)
      image.generate_matching_symbol(number_of_symbols)
    end
  end
end
