require "rails_helper"

RSpec.describe "API::Internal::MarketingAssets", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def pdf_upload
    Rack::Test::UploadedFile.new(
      StringIO.new("%PDF-1.4 fake kit"),
      "application/pdf",
      original_filename: "kit.pdf",
    )
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  describe "POST /api/internal/marketing_assets" do
    it "returns 401 without a valid bearer token" do
      post "/api/internal/marketing_assets", params: { slug: "classroom-kit", file: pdf_upload }
      expect(response).to have_http_status(:unauthorized)
    end

    it "hosts the uploaded PDF at a stable slug and returns the public URL" do
      allow(ENV).to receive(:[]).with("CDN_HOST").and_return("https://cdn.example.com")

      expect {
        post "/api/internal/marketing_assets",
             params: { slug: "classroom-kit", title: "AAC Classroom Kit", file: pdf_upload },
             headers: auth_headers
      }.to change(MarketingAsset, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["slug"]).to eq("classroom-kit")
      expect(body["title"]).to eq("AAC Classroom Kit")
      expect(body["url"]).to eq("https://cdn.example.com/marketing_assets/classroom-kit.pdf")
    end

    it "is idempotent on re-upload (same slug -> same record and URL)" do
      post "/api/internal/marketing_assets",
           params: { slug: "classroom-kit", file: pdf_upload }, headers: auth_headers

      expect {
        post "/api/internal/marketing_assets",
             params: { slug: "classroom-kit", title: "v2", file: pdf_upload }, headers: auth_headers
      }.not_to change(MarketingAsset, :count)

      expect(response).to have_http_status(:created)
      asset = MarketingAsset.find_by(slug: "classroom-kit")
      expect(asset.title).to eq("v2")
      expect(asset.file.key).to eq("marketing_assets/classroom-kit.pdf")
    end

    it "422s when slug is missing" do
      post "/api/internal/marketing_assets", params: { file: pdf_upload }, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("slug_required")
    end

    it "422s when file is missing" do
      post "/api/internal/marketing_assets", params: { slug: "classroom-kit" }, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("file_required")
    end
  end

  describe "GET /api/internal/marketing_assets/:slug" do
    it "returns the hosted asset URL" do
      MarketingAsset.upsert_pdf!(slug: "classroom-kit", bytes: "%PDF x", title: "Kit")

      get "/api/internal/marketing_assets/classroom-kit", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["slug"]).to eq("classroom-kit")
      expect(body["url"]).to be_present
    end

    it "404s for an unknown slug" do
      get "/api/internal/marketing_assets/nope", headers: auth_headers
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("marketing_asset_not_found")
    end
  end
end
