require "net/http"
require "json"

# Proxies YouTube Data API v3 search so the API key never reaches the client.
# Results are restricted to safe-search strict, embeddable videos — tiles play
# in an iframe, so a non-embeddable result would attach but never play.
#
# Returns nil on any failure (missing key, HTTP error, malformed body) — the
# controller maps that to a generic error response.
class YoutubeSearchService
  BASE_URL = "https://www.googleapis.com/youtube/v3/search"
  MAX_RESULTS = 12

  def self.enabled?
    ENV["YOUTUBE_API_KEY"].present?
  end

  def initialize(query)
    @query = query.to_s.strip
  end

  def search
    return nil unless self.class.enabled?

    uri = URI(BASE_URL)
    uri.query = URI.encode_www_form(
      key: ENV["YOUTUBE_API_KEY"],
      part: "snippet",
      type: "video",
      safeSearch: "strict",
      videoEmbeddable: "true",
      maxResults: MAX_RESULTS,
      q: @query,
    )
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    parse(JSON.parse(response.body))
  rescue StandardError => e
    Rails.logger.error "YoutubeSearchService error: #{e.message}"
    nil
  end

  private

  # Only ids that pass the same validation as user-pasted URLs are returned,
  # so search results can never smuggle a value the attach endpoint would
  # reject (or worse, accept unvalidated).
  def parse(body)
    Array(body["items"]).filter_map do |item|
      id = item.dig("id", "videoId")
      next unless id.to_s.match?(YoutubeUrlParser::VIDEO_ID_RE)

      snippet = item["snippet"] || {}
      {
        youtube_id: id,
        title: snippet["title"],
        channel_title: snippet["channelTitle"],
        thumbnail_url: snippet.dig("thumbnails", "medium", "url") ||
          snippet.dig("thumbnails", "default", "url"),
      }.with_indifferent_access
    end
  end
end
