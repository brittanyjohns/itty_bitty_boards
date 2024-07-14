class GetSymbolsJob
  include Sidekiq::Job
  sidekiq_options queue: "default", retry: false

  def perform(image_ids, number_of_symbols = 5)
    image_ids.each do |image_id|
      image = Image.find(image_id)
      image.update(status: "generating") unless image.generating?
      image.generate_matching_symbol(number_of_symbols)
      image.update(status: "finished") unless image.finished?
    end
  end
end
