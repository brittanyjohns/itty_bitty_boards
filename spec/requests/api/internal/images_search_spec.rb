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
end
