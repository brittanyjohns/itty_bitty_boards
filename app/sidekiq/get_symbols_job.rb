class GetSymbolsJob
  include Sidekiq::Job

  def perform(image_ids, number_of_symbols=5)
    image_ids.each do |image_id|
      image = Image.find(image_id)
      image.update(status: "generating") unless image.generating?
      image.generate_matching_symbol(number_of_symbols)
      sleep 2
      image.update(status: "finished") unless image.finished?
    end
  end
end
