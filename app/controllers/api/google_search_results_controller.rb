class API::GoogleSearchResultsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!

  # Test the service
  # puts "GoogleSearchResultsService loaded\n"
  # test_query = "Coffee"
  # puts "Searching for #{test_query}\n\n"
  # search_results = GoogleSearchResultsService.new(test_query).search
  # puts "Search results class: #{search_results.class}"
  # image_results = search_results[:images_results]
  # puts "Image results class: #{image_results.class}"

  # image_results.each do |image|
  #   puts "URL: #{image[:original]}"
  # end

  # puts "\n\n"

  def image_search
    puts "\n**google_images endpoint hit**\n"
    search_results = GoogleSearchResultsService.new(params[:q]).search
    render json: search_results
  end
end
