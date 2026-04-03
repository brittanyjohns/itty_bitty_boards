class API::AudioController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[play]

  def play
    url = params[:url]
    # VERY IMPORTANT: whitelist or hardcode for safety in prod
    raise "missing url" if url.blank?

    # Stream it through Rails
    upstream = Faraday.get(url)
    send_data upstream.body,
      type: upstream.headers["content-type"] || "audio/mpeg",
      disposition: "inline"
  end
end
