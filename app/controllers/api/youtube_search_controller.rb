class API::YoutubeSearchController < API::ApplicationController
  # Signed-in only (inherited authenticate_token!), same posture as
  # attach_youtube_video — the admin gate lives on the Video tab UI.
  def search
    query = params[:q].to_s.strip
    if query.blank?
      return render json: { error: "Query parameter is required" }, status: :bad_request
    end
    unless YoutubeSearchService.enabled?
      return render json: { error: "search_unavailable" }, status: :service_unavailable
    end

    results = YoutubeSearchService.new(query).search
    if results
      render json: { videos: results }
    else
      render json: { error: "Failed to fetch search results" }, status: :internal_server_error
    end
  end
end
