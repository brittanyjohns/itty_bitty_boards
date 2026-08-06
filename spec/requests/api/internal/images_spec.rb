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

    # #575, point 2: the payload carried no licensing at all, so art attached
    # by `bulk` read as "not commercial safe, no license record" whether or not
    # that was true — and these boards feed the printables pipeline.
    describe "licensing" do
      def image_with_doc(label:, source_type: "OpenAI", license: nil, user: admin_user)
        img = Image.create!(label: label, user_id: user.id)
        doc = img.docs.create!(user_id: user.id, source_type: source_type, license: license, raw: label)
        doc.image.attach(io: StringIO.new(file_fixture("sample.png").read),
                         filename: "#{label}.png", content_type: "image/png")
        img
      end

      it "reports a commercial-safe image as safe, with its source and original URL" do
        safe = image_with_doc(label: "safe-carrot", source_type: "OpenAI")

        get "/api/internal/images/#{safe.id}", headers: auth_headers

        body = JSON.parse(response.body)
        expect(body["has_art"]).to be true
        expect(body["commercial_safe"]).to be true
        expect(body["source_type"]).to eq("OpenAI")
        expect(body["original_url"]).to be_present
      end

      it "reports an ARASAAC-style image as unsafe and attribution-required" do
        unsafe = image_with_doc(label: "arasaac-carrot", source_type: "ObfImport",
                                license: { "type" => "CC BY-NC-SA", "author_name" => "Sergio Palao" })

        get "/api/internal/images/#{unsafe.id}", headers: auth_headers

        body = JSON.parse(response.body)
        expect(body["commercial_safe"]).to be false
        expect(body["attribution_required"]).to be true
        expect(body["share_alike"]).to be true
        expect(body["license"]["author_name"]).to eq("Sergio Palao")
      end

      it "distinguishes no artwork from unusable artwork" do
        get "/api/internal/images/#{image.id}", headers: auth_headers

        body = JSON.parse(response.body)
        expect(body["has_art"]).to be false
        expect(body["license"]).to be_nil
        expect(body["commercial_safe"]).to be false
      end

      it "admits share-alike with include_share_alike" do
        sa = image_with_doc(label: "sa-carrot", source_type: "ObfImport", license: { "type" => "CC BY-SA" })

        get "/api/internal/images/#{sa.id}", params: { include_share_alike: "true" }, headers: auth_headers

        expect(JSON.parse(response.body)["commercial_safe"]).to be true
      end
    end
  end
end
