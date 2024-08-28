require "unsplash"

Unsplash.configure do |config|
  config.application_access_key = ENV["UNSPLASH_ACCESS_KEY"]
  config.application_secret = ENV["UNSPLASH_SECRET_KEY"]
  config.utm_source = "speakanyway"
end

class UnsplashImageSearchService
  def initialize(query)
    @query = query
  end

  def search
    Unsplash::Photo.search(@query, page = 1, per_page = 10)
  end
end

# Test the service
puts "UnsplashImageSearchService loaded\n"
test_query = "Coffee"
puts "Searching for #{test_query}\n\n"
search_results = UnsplashImageSearchService.new(test_query).search
pp search_results
