require "rails_helper"

RSpec.describe "API::Internal::Boards search", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  def admin_board(name:, description: nil, tags: [], published: false, **attrs)
    create(:board, user: admin, name: name, description: description,
                   tags: tags, published: published, sub_board: false, **attrs)
  end

  def body = JSON.parse(response.body)

  describe "GET /api/internal/boards/search" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/boards/search"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the full admin scope when no params are given" do
      admin_board(name: "Animals")
      get "/api/internal/boards/search", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |b| b["name"] }).to include("Animals")
      expect(body).to include("page", "total_pages", "total_count")
    end

    it "matches on a name prefix" do
      admin_board(name: "Animals")
      get "/api/internal/boards/search", params: { q: "anim" }, headers: auth_headers
      expect(body["results"].map { |b| b["name"] }).to eq(["Animals"])
    end

    it "matches on a description substring" do
      admin_board(name: "Zoo", description: "all about animals here")
      get "/api/internal/boards/search", params: { q: "animals" }, headers: auth_headers
      expect(body["results"].map { |b| b["name"] }).to eq(["Zoo"])
    end

    it "returns unpublished boards by default" do
      admin_board(name: "Draft board", published: false)
      get "/api/internal/boards/search", headers: auth_headers
      expect(body["results"].map { |b| b["name"] }).to include("Draft board")
    end

    it "filters to published only when asked" do
      admin_board(name: "Draft board", published: false)
      admin_board(name: "Live board", published: true)
      get "/api/internal/boards/search", params: { published: "true" }, headers: auth_headers

      names = body["results"].map { |b| b["name"] }
      expect(names).to include("Live board")
      expect(names).not_to include("Draft board")
    end

    it "requires all tags by default" do
      admin_board(name: "Both", tags: ["printable", "core"])
      admin_board(name: "One", tags: ["printable"])
      get "/api/internal/boards/search", params: { tags: "printable,core" }, headers: auth_headers

      expect(body["results"].map { |b| b["name"] }).to eq(["Both"])
    end

    it "requires any tag when tag_match is any" do
      admin_board(name: "One", tags: ["printable"])
      get "/api/internal/boards/search",
          params: { tags: "printable,core", tag_match: "any" }, headers: auth_headers

      expect(body["results"].map { |b| b["name"] }).to include("One")
    end

    it "returns the lean payload shape" do
      admin_board(name: "Animals", description: "zoo", tags: ["printable"], published: true)
      get "/api/internal/boards/search", params: { q: "anim" }, headers: auth_headers

      expect(body["results"].first).to include(
        "id", "slug", "name", "description", "tags", "published", "predefined",
        "board_type", "image_count", "preview_image_url", "created_at", "updated_at"
      )
    end

    it "excludes boards owned by another user" do
      other = create(:user)
      create(:board, user: other, name: "Theirs", sub_board: false)
      get "/api/internal/boards/search", params: { q: "Theirs" }, headers: auth_headers

      expect(body["results"]).to eq([])
    end
  end

  describe "GET /api/internal/boards/tags" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/boards/tags"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns tags with counts" do
      admin_board(name: "A", tags: ["printable", "core"])
      admin_board(name: "B", tags: ["printable"])
      get "/api/internal/boards/tags", headers: auth_headers

      expect(response).to have_http_status(:ok)
      printable = body["tags"].find { |t| t["tag"] == "printable" }
      expect(printable["count"]).to eq(2)
    end

    it "includes tags found only on unpublished boards" do
      admin_board(name: "Draft", tags: ["draftonly"], published: false)
      get "/api/internal/boards/tags", headers: auth_headers

      expect(body["tags"].map { |t| t["tag"] }).to include("draftonly")
    end

    it "respects the published filter" do
      admin_board(name: "Draft", tags: ["draftonly"], published: false)
      get "/api/internal/boards/tags", params: { published: "true" }, headers: auth_headers

      expect(body["tags"].map { |t| t["tag"] }).not_to include("draftonly")
    end
  end
end
