require "net/http"
require "json"

class GoogleResultsService
  BASE_URL = "https://customsearch.googleapis.com/customsearch/v1"

  def initialize(query, start_index = 1)
    @query = query
    @start_index = start_index
    @google_custom_search_api_key = ENV["GOOGLE_CUSTOM_SEARCH_API_KEY"]
    @google_custom_search_cx = ENV["GOOGLE_CUSTOM_SEARCH_CX"]

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
    uri = URI(search_url)
    response = Net::HTTP.get(uri)
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
    queries["nextPage"][0]["startIndex"] if queries["nextPage"].present?
  end

  def filtered_search_results
    filtered = []
    search_images&.map do |image|
      img_obj = {
        title: image["title"],
        link: image["link"],  # Direct image link
        snippet: image["snippet"],
        thumbnail: image["image"]["thumbnailLink"],
        context: image["image"]["contextLink"],
        fileFormat: image["fileFormat"],
      }.with_indifferent_access
      unless image["fileFormat"].blank? || image["fileFormat"].include?("svg")
        filtered << img_obj
      end
    end
    puts "Filtered images: #{filtered.count}"
    puts " \n#{filtered.inspect}\n"
    filtered
  end

  def images_api_view
    filtered_search_results&.map do |image|
      puts "Image: #{image["title"]}"
      puts "Image2: #{image[:title]}"
      {
        title: image["title"],
        link: image["link"],  # Direct image link
        snippet: image["snippet"],
        thumbnail: image["thumbnail"],
        context: image["context"],
        fileFormat: image["fileFormat"],
        startIndex: nextStartIndex,
      }.with_indifferent_access
    end
  end

  def next_page
    @start_index += 10
    search
  end
end