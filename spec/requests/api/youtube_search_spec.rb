require "rails_helper"

RSpec.describe "API::YoutubeSearch", type: :request do
  let!(:user) { create(:user) }

  describe "POST /api/youtube_search" do
    it "requires authentication" do
      post "/api/youtube_search", params: { q: "wheels on the bus" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "requires a query" do
      post "/api/youtube_search", params: { q: "" }, headers: auth_headers(user)

      expect(response).to have_http_status(:bad_request)
    end

    it "returns videos from the search service" do
      results = [{ "youtube_id" => "dQw4w9WgXcQ", "title" => "A Song" }]
      service = instance_double(YoutubeSearchService, search: results)
      allow(YoutubeSearchService).to receive(:enabled?).and_return(true)
      allow(YoutubeSearchService).to receive(:new).with("wheels on the bus").and_return(service)

      post "/api/youtube_search", params: { q: "wheels on the bus" }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["videos"]).to eq(results)
    end

    it "returns 503 search_unavailable when no API key is configured" do
      allow(YoutubeSearchService).to receive(:enabled?).and_return(false)

      post "/api/youtube_search", params: { q: "wheels on the bus" }, headers: auth_headers(user)

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body)["error"]).to eq("search_unavailable")
    end

    it "returns a generic error when the search fails" do
      service = instance_double(YoutubeSearchService, search: nil)
      allow(YoutubeSearchService).to receive(:enabled?).and_return(true)
      allow(YoutubeSearchService).to receive(:new).and_return(service)

      post "/api/youtube_search", params: { q: "wheels on the bus" }, headers: auth_headers(user)

      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)["error"]).to eq("Failed to fetch search results")
    end
  end
end
