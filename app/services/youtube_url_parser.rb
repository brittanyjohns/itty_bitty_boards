# Parses a user-pasted YouTube URL into a validated 11-character video id.
#
# Only the id is ever persisted or used to build an embed URL — the raw URL is
# discarded, so client input can never reach an iframe src. Non-YouTube hosts
# and malformed ids are rejected (returns nil).
class YoutubeUrlParser
  ALLOWED_HOSTS = %w[
    youtube.com
    www.youtube.com
    m.youtube.com
    music.youtube.com
    youtu.be
    youtube-nocookie.com
    www.youtube-nocookie.com
  ].freeze

  VIDEO_ID_RE = /\A[A-Za-z0-9_-]{11}\z/

  # Returns the 11-char video id, or nil when the URL isn't a recognizable
  # YouTube video link.
  def self.video_id(raw_url)
    return nil if raw_url.blank?

    uri = begin
      URI.parse(raw_url.to_s.strip)
    rescue URI::InvalidURIError
      return nil
    end
    # Tolerate URLs pasted without a scheme ("youtu.be/abc...").
    if uri.host.nil? && !raw_url.to_s.strip.start_with?("/")
      return video_id("https://#{raw_url.to_s.strip}")
    end
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    return nil unless ALLOWED_HOSTS.include?(uri.host&.downcase)

    candidate =
      if uri.host&.downcase == "youtu.be"
        uri.path.to_s.delete_prefix("/").split("/").first
      elsif uri.path.to_s.start_with?("/embed/", "/shorts/", "/live/")
        uri.path.to_s.split("/")[2]
      else
        Rack::Utils.parse_query(uri.query.to_s)["v"]
      end

    candidate.presence&.match?(VIDEO_ID_RE) ? candidate : nil
  end
end
