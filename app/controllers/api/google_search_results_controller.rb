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
    image_search_service = GoogleResultsService.new(params[:q])
    image_search_service.search
    # search_results = image_search_service.images_api_view
    image_results = image_search_service.images_api_view

    render json: image_results
  end

  #   export interface ImageResult {
  #   link: string;
  #   title: string;
  #   thumbnail: string;
  #   snippet?: string;
  #   context?: string;
  # }

  def save_image_result
    puts "\n**save_image_result endpoint hit**\n #{params.inspect}"
    src = params[:imageResult][:link]
    title = params[:query]
    long_title = params[:imageResult][:title]
    file_format = params[:imageResult][:fileFormat]
    user_id = current_user.id
    puts "Saving image result: #{src}, #{title}, #{long_title}, #{user_id} , #{file_format}"
    image = Image.create_image_from_google_search(src, title, long_title, file_format, user_id)
    render json: image
  end
end
