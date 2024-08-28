require "net/http"
require "json"

class GoogleResultsService
  template = "https://www.googleapis.com/customsearch/v1?q={searchTerms}&num={count?}&start={startIndex?}&lr={language?}&safe={safe?}&cx={cx?}&sort={sort?}&filter={filter?}&gl={gl?}&cr={cr?}&googlehost={googleHost?}&c2coff={disableCnTwTranslation?}&hq={hq?}&hl={hl?}&siteSearch={siteSearch?}&siteSearchFilter={siteSearchFilter?}&exactTerms={exactTerms?}&excludeTerms={excludeTerms?}&linkSite={linkSite?}&orTerms={orTerms?}&dateRestrict={dateRestrict?}&lowRange={lowRange?}&highRange={highRange?}&searchType={searchType}&fileType={fileType?}&rights={rights?}&imgSize={imgSize?}&imgType={imgType?}&imgColorType={imgColorType?}&imgDominantColor={imgDominantColor?}&alt=json"

  def initialize(query)
    @query = query
    # GET https://customsearch.googleapis.com/customsearch/v1

    @google_custom_search_api_key = ENV["GOOGLE_CUSTOM_SEARCH_API_KEY"]
    @google_custom_search_cx = ENV["GOOGLE_CUSTOM_SEARCH_CX"]

    puts "GoogleResultsService initialized with query: #{@query}"
    puts "GoogleResultsService initialized with API Key: #{@google_custom_search_api_key}"
    puts "GoogleResultsService initialized with CX: #{@google_custom_search_cx}"

    params = {
      api_key: @google_custom_search_api_key,
      cx: @google_custom_search_cx,

      safe: "active",
      #   image_color_type: 'color',
      SearchType: "image",
      q: query,
      rights: "cc_publicdomain",

    }
    @search = "https://customsearch.googleapis.com/customsearch/v1?key=#{params[:api_key]}&cx=#{params[:cx]}&q=#{params[:q]}&searchType=image&safe=active&rights=cc_publicdomain"
    puts "Search URL: #{@search}"
  end

  def search
    @search.inspect
    uri = URI(@search)
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

  def search_links
    search_results[:organic_results]
  end

  def images_api_view
    search_images.map do |image|
      {
        title: image["title"],
        link: image["link"],
        snippet: image["snippet"],
        thumbnail: image["image"]["thumbnailLink"],
        context: image["image"]["contextLink"],
        fileFormat: image["fileFormat"],
      }
    end
  end

  def search_image_urls
    urls = []
    search_images.each_with_index do |image, index|
      urls << image["link"]
      puts "\nImage #{index}: "
      pp image
    end
    urls
  end
end

# # Test the service
# puts "GoogleResultsService loaded\n"
# test_query = "Coffee"
# puts "Searching for #{test_query}\n\n"
# google_service = GoogleResultsService.new(test_query)
# google_service.search
# search_images = google_service.search_image_urls
# # puts "Search images: #{search_images.inspect}"

# puts "\n\n"
# puts "All done."

# puts "\n\n"

# # search_results.each do |image|
# #   puts "URL: #{image["original"]}"
# # end

# puts "\nGoogleResultsService finished"
# exit 0
