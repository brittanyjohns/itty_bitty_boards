require "net/http"
require "json"

class GoogleResultsService
  BASE_URL = "https://customsearch.googleapis.com/customsearch/v1"

  def initialize(query, start_index = 1)
    @query = query
    @start_index = start_index
    @google_custom_search_api_key = ENV["GOOGLE_CUSTOM_SEARCH_API_KEY"]
    @google_custom_search_cx = ENV["GOOGLE_CUSTOM_SEARCH_CX"]

    puts "GoogleResultsService initialized with query: #{@query}"
    puts "GoogleResultsService initialized with API Key: #{@google_custom_search_api_key}"
    puts "GoogleResultsService initialized with CX: #{@google_custom_search_cx}"

    @params = {
      key: @google_custom_search_api_key,
      cx: @google_custom_search_cx,
      safe: "active",
      searchType: "image",
      q: @query,
      rights: "cc_publicdomain",
      start: @start_index,
      num: 10, # Number of results per page (max 10)
    }
  end

  def add_params(extra_params)
    return unless extra_params&.is_a?(Hash)
    extra_params.each do |key, value|
      key_to_set = key.to_s.camelize(:lower)
      puts "Adding param: #{key_to_set} = #{value}"
      @params[key_to_set.to_sym] = value
    end
  end

  def build_search_url
    uri = URI(BASE_URL)
    uri.query = URI.encode_www_form(@params)
    uri.to_s
  end

  def search
    search_url = build_search_url
    puts "Search URL: #{search_url}"
    uri = URI(search_url)
    response = Net::HTTP.get(uri)
    puts "Response: #{response}"
    @search_results = JSON.parse(response)

    response
  end

  def search_results
    @search_results ||= search
  end

  def search_images
    search_results["items"]
  end

  def queries
    search_results["queries"]
  end

  def nextStartIndex
    queries["nextPage"][0]["startIndex"]
  end

  def images_api_view
    search_images&.map do |image|
      {
        title: image["title"],
        link: image["link"],
        snippet: image["snippet"],
        thumbnail: image["image"]["thumbnailLink"],
        context: image["image"]["contextLink"],
        fileFormat: image["fileFormat"],
        startIndex: nextStartIndex,
      }
    end
  end

  def next_page
    @start_index += 10
    search
  end
end

# # Test the service
# puts "GoogleResultsService loaded\n"
# test_query = "Coffee"
# puts "Searching for #{test_query}\n\n"
# google_service = GoogleResultsService.new(test_query)

# # Search first page
# google_service.search
# search_images = google_service.images_api_view
# puts "First page search images: #{search_images.inspect}"

# # Search next page
# google_service.next_page
# next_page_images = google_service.images_api_view
# puts "Next page search images: #{next_page_images.inspect}"

# puts "\nGoogleResultsService finished"
# exit 0
