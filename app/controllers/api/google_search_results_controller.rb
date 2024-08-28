class API::GoogleSearchResultsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!

  # Test the service
  # puts "GoogleResultsService loaded\n"
  # test_query = "Coffee"
  # puts "Searching for #{test_query}\n\n"
  # search_results = GoogleResultsService.new(test_query).search
  # puts "Search results class: #{search_results.class}"
  # image_results = search_results[:images_results]
  # puts "Image results class: #{image_results.class}"

  # image_results.each do |image|
  #   puts "URL: #{image[:original]}"
  # end

  # puts "\n\n"

  def image_search
    puts "\n**google_images endpoint hit**\n"
    search_results = GoogleResultsService.new(params[:q]).search
    render json: search_results
  end

  def save_image_result
    puts "\n**save_image_result endpoint hit**\n"
    src = params[:src]
    title = params[:title]
    long_title = params[:long_title]
    user_id = current_user.id
    puts "Saving image result: #{src}, #{title}, #{long_title}, #{user_id}"
    image = Image.create_image_from_google_search(src, title, long_title, user_id)
    render json: image
  end
end
