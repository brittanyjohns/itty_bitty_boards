require "rails_helper"

RSpec.describe "API::Internal::Images search", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let(:json_headers) { auth_headers.merge("Content-Type" => "application/json") }
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  def image_with_doc(label:, source_type: "OpenAI", license: nil)
    image = Image.create!(label: label, user_id: admin.id)
    doc = image.docs.create!(user_id: admin.id, source_type: source_type, license: license, raw: label)
    doc.image.attach(
      io: StringIO.new(file_fixture("sample.png").read),
      filename: "#{label}.png",
      content_type: "image/png",
    )
    image
  end

  def body = JSON.parse(response.body)

  describe "GET /api/internal/images/search" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/images/search", params: { q: "apple" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when q is blank" do
      get "/api/internal/images/search", params: { q: "" }, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns matching images" do
      image_with_doc(label: "apple")
      get "/api/internal/images/search", params: { q: "apple" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(body["query"]).to eq("apple")
      expect(body["results"].first["label"]).to eq("apple")
      expect(body["results"].first["original_url"]).to be_present
    end

    it "filters on commercial_safe when requested" do
      image_with_doc(label: "nc", source_type: "ObfImport", license: { "type" => "CC BY-NC" })
      get "/api/internal/images/search",
          params: { q: "nc", commercial_safe: "true" }, headers: auth_headers

      expect(body["results"]).to eq([])
    end

    it "admits share-alike images with include_share_alike" do
      image_with_doc(label: "sa", source_type: "ObfImport", license: { "type" => "CC BY-SA" })
      get "/api/internal/images/search",
          params: { q: "sa", commercial_safe: "true", include_share_alike: "true" },
          headers: auth_headers

      expect(body["results"].size).to eq(1)
    end

    it "treats a present-but-empty limit param as absent (the default), not zero" do
      11.times { |i| image_with_doc(label: "widget") }
      get "/api/internal/images/search",
          params: { q: "widget", limit: "" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(body["results"].size).to eq(Images::LabelSearch::DEFAULT_LIMIT)
    end
  end

  describe "POST /api/internal/images/search" do
    it "returns 401 without a valid bearer token" do
      post "/api/internal/images/search",
           params: { labels: ["apple"] }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when labels is missing" do
      post "/api/internal/images/search", params: {}.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when labels is empty" do
      post "/api/internal/images/search", params: { labels: [] }.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when labels exceeds the cap" do
      post "/api/internal/images/search",
           params: { labels: Array.new(101) { |i| "w#{i}" } }.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns a key for every requested label, including misses" do
      image_with_doc(label: "apple")
      post "/api/internal/images/search",
           params: { labels: ["apple", "nothinghere"] }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(body["results"].keys).to contain_exactly("apple", "nothinghere")
      expect(body["results"]["apple"].size).to eq(1)
      expect(body["results"]["nothinghere"]).to eq([])
    end

    it "keys results by the caller's label verbatim" do
      image_with_doc(label: "apple")
      post "/api/internal/images/search",
           params: { labels: ["  Apple  "] }.to_json, headers: json_headers

      expect(body["results"].keys).to eq(["  Apple  "])
    end

    it "caps limit_per_label at 25 even when a higher value is requested and more matches exist" do
      # 30 images all labeled "widget" so there are more than 25 possible
      # matches to return.
      30.times { image_with_doc(label: "widget") }

      post "/api/internal/images/search",
           params: { labels: ["widget"], limit_per_label: 30 }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(body["results"]["widget"].size).to eq(25)
    end
  end

  # #575: search and board_images/bulk disagreed about which Image a label
  # resolves to, so a pre-flight art check reported core vocabulary as missing
  # while bulk was attaching exact-label art for the same word.
  describe "agreement with board_images/bulk" do
    it "ranks the exact-label image first instead of phrase matches" do
      ["i want to buy this", "want slide", "i want pasta", "dont want"].each do |phrase|
        image_with_doc(label: phrase)
      end
      exact = image_with_doc(label: "want")

      get "/api/internal/images/search", params: { q: "want", limit: 5 }, headers: auth_headers

      expect(body["results"].first["id"]).to eq(exact.id)
      expect(body["results"].first["label"]).to eq("want")
    end

    it "reports the exact-label image in a bulk search too" do
      image_with_doc(label: "where are the lions?")
      exact = image_with_doc(label: "where")

      post "/api/internal/images/search",
           params: { labels: ["where"], limit_per_label: 1 }.to_json, headers: json_headers

      expect(body["results"]["where"].map { |r| r["id"] }).to eq([exact.id])
    end

    it "surfaces what bulk would attach when resolve=true" do
      # Private admin-owned art: outside search's scope, inside the resolver's.
      hidden = Image.create!(label: "resolve-only", user_id: admin.id, is_private: true)
      doc = hidden.docs.create!(user_id: admin.id, source_type: "OpenAI", raw: "resolve-only")
      doc.image.attach(io: StringIO.new(file_fixture("sample.png").read),
                       filename: "r.png", content_type: "image/png")

      get "/api/internal/images/search", params: { q: "resolve-only" }, headers: auth_headers
      expect(body["results"]).to eq([])

      get "/api/internal/images/search",
          params: { q: "resolve-only", resolve: "true" }, headers: auth_headers

      expect(body["results"].first["id"]).to eq(hidden.id)
      expect(body["results"].first["match"]).to eq("resolve")
    end

    it "supports resolve in the bulk search" do
      exact = image_with_doc(label: "up")

      post "/api/internal/images/search",
           params: { labels: ["up"], resolve: true, limit_per_label: 1 }.to_json, headers: json_headers

      expect(body["results"]["up"].first["id"]).to eq(exact.id)
      expect(body["results"]["up"].first["match"]).to eq("resolve")
    end
  end
end
