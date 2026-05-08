require "rails_helper"

RSpec.describe "API::Internal::Images", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin_user) { create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  describe "POST /api/internal/images" do
    context "without a valid bearer token" do
      it "returns 401" do
        post "/api/internal/images", params: { image: { label: "apple" } }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with a valid bearer token" do
      it "creates an image and returns 201" do
        expect {
          post "/api/internal/images",
               params: { image: { label: "apple", image_prompt: "a red apple" } }.to_json,
               headers: auth_headers.merge("Content-Type" => "application/json")
        }.to change(Image, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(Image.last.label).to eq("apple")
        expect(Image.last.user_id).to eq(User::DEFAULT_ADMIN_ID)
      end
    end
  end

  describe "POST /api/internal/images/generate" do
    it "enqueues GenerateImageJob and returns 202" do
      expect {
        post "/api/internal/images/generate",
             params: { image: { label: "banana", image_prompt: "a yellow banana" } }.to_json,
             headers: auth_headers.merge("Content-Type" => "application/json")
      }.to change(GenerateImageJob.jobs, :size).by(1)

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("generating")
      expect(body["label"]).to eq("banana")

      job = GenerateImageJob.jobs.last
      expect(job["args"][0]).to eq(body["id"])
      expect(job["args"][1]).to eq(User::DEFAULT_ADMIN_ID)
    end
  end

  describe "GET /api/internal/images/:id" do
    let!(:image) { create(:image, label: "carrot", user_id: admin_user.id) }

    it "returns the image status payload" do
      get "/api/internal/images/#{image.id}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(image.id)
      expect(body["label"]).to eq("carrot")
      expect(body).to have_key("status")
    end
  end
end
