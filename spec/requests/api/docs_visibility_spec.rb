require "rails_helper"

# A doc owned by nil or DEFAULT_ADMIN_ID is library art; any other doc is
# private to its owner. API::DocsController loaded docs with an unscoped find
# on every action but #update/#destroy, so a signed-in user could read, list,
# re-parent or attach docs that were not theirs.
RSpec.describe "API::Docs visibility", type: :request do
  let!(:owner)    { create(:user) }
  let!(:stranger) { create(:user) }
  let!(:admin)    { create(:admin_user) }

  let!(:image)       { create(:image, user: owner, is_private: false) }
  let!(:private_doc) { create(:doc, documentable: image, user: owner) }

  describe "GET /api/docs/:id" do
    it "404s another user's private doc" do
      get "/api/docs/#{private_doc.id}", headers: auth_headers(stranger)

      expect(response).to have_http_status(:not_found)
    end

    it "returns the owner's own doc" do
      get "/api/docs/#{private_doc.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(private_doc.id)
    end

    it "returns library art to anyone signed in" do
      library_doc = create(:doc, documentable: image, user_id: nil)

      get "/api/docs/#{library_doc.id}", headers: auth_headers(stranger)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the listings" do
    it "refuses GET /api/docs to a non-admin" do
      get "/api/docs", headers: auth_headers(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses GET /api/docs/deleted to a non-admin" do
      get "/api/docs/deleted", headers: auth_headers(stranger)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "re-parenting a doc" do
    let(:strangers_image) { create(:image, user: stranger) }

    it "refuses move to a user who cannot edit the doc" do
      post "/api/docs/#{private_doc.id}/move",
           params: { documentable_type: "Image", documentable_id: strangers_image.id },
           headers: auth_headers(stranger)

      expect(response).to have_http_status(:forbidden)
      expect(private_doc.reload.documentable_id).to eq(image.id)
    end

    it "refuses find_or_create_image to a user who cannot edit the doc" do
      post "/api/docs/#{private_doc.id}/find_or_create_image",
           params: { label: "stolen" },
           headers: auth_headers(stranger)

      expect(response).to have_http_status(:forbidden)
      expect(private_doc.reload.documentable_id).to eq(image.id)
    end
  end

  describe "POST /api/docs" do
    let(:upload) do
      Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/sample.png"), "image/png")
    end

    it "refuses to attach a doc to another user's private image" do
      private_image = create(:image, user: owner, is_private: true)

      expect {
        post "/api/docs",
             params: { doc: { documentable_id: private_image.id, documentable_type: "Image", image: upload } },
             headers: auth_headers(stranger)
      }.not_to change(Doc, :count)

      expect(response).to have_http_status(:not_found)
    end
  end
end
