require "google_search_results"
# {
# "position":
# 1,
# "thumbnail":
# "https://serpapi.com/searches/66ce789a7b05cabe3d9ac786/images/c4739c6c7f0a9317cd64b799d71071a1b8fbfa41e4a2c76a13e9ff80c66af52c.jpeg",
# "related_content_id":
# "b0JsYkFFclBGYWVsY01cIixcInFjQ0JMTnpGcE1wUjRN",
# "serpapi_related_content_link":
# "https://serpapi.com/search.json?engine=google_images_related_content&gl=us&hl=en&q=Coffee&related_content_id=b0JsYkFFclBGYWVsY01cIixcInFjQ0JMTnpGcE1wUjRN",
# "source":
# "Wikipedia, the free encyclopedia",
# "source_logo":
# "https://serpapi.com/searches/66ce789a7b05cabe3d9ac786/images/c4739c6c7f0a9317cd64b799d71071a14e6305fc658fc23feebacb9ccdbdbabc.png",
# "title":
# "Coffee - Wikipedia",
# "link":
# "https://en.wikipedia.org/wiki/coffee",
# "original":
# "https://upload.wikimedia.org/wikipedia/commons/thumb/e/e4/Latte_and_dark_coffee.jpg/1200px-Latte_and_dark_coffee.jpg",
# "original_width":
# 1200,
# "original_height":
# 750,
# "is_product":
# false
# },
class GoogleSearchResultsService
  def initialize(query)
    @query = query
    params = {
      api_key: ENV["SERPAPI_API_KEY"],
      engine: "google_images",
      google_domain: "google.com",
      q: query,
      hl: "en",
      gl: "us",
      safe: "active",
      num: 10,
      rights: "cc_publicdomain|cc_attribute|cc_sharealike|cc_noncommercial|cc_nonderived", # Filter for usage rights
    #   rights: "cc_publicdomain|cc_attribute|cc_sharealike" # Filter for commercial use <== TODO: Figure out if we need this
    }
    @search = GoogleSearch.new(params)
  end

  def search
    @search.get_hash
  end

  def search_images
    search_results = search
    search_results[:images_results]
  end

  def search_links
    search_results = search
    search_results[:organic_results]
  end

  def search_image_urls
    search_images.map { |image| image[:original] }
  end
end

# Test the service
puts "GoogleSearchResultsService loaded\n"
test_query = "Coffee"
puts "Searching for #{test_query}\n\n"
search_results = GoogleSearchResultsService.new(test_query).search
puts "Search results class: #{search_results.class}"
image_results = search_results[:images_results]
puts "Image results class: #{image_results.class}"

search_images = search_results[:images_results] || []

puts "Search images class: #{search_images.class}"
search_images.each do |image|
  puts "URL: #{image[:original]}"
  puts "Title: #{image[:title]}"
end

puts "\n\n"
puts "All done."

puts "\n\n"

# search_results.each do |image|
#   puts "URL: #{image["original"]}"
# end

puts "\nGoogleSearchResultsService finished"
exit 0
