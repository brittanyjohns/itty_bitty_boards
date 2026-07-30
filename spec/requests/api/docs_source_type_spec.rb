require "rails_helper"

# Docs created through user-facing upload endpoints must record
# `source_type: "User"`. Provenance is what licensing decisions key on
# (Images::CommercialLicense, and OBF/OBZ export), and these endpoints
# historically left it nil — indistinguishable from "unknown origin", which
# fails closed and would exclude a user's own photos from their own export.
RSpec.describe "Doc source_type provenance", type: :request do
  let!(:user)  { create(:user) }
  let!(:image) { create(:image, user: user) }

  # Matches what the client actually sends: a multipart file under
  # image[docs][image] (see FileUploadForm.tsx), not a base64 payload.
  let(:upload) do
    Rack::Test::UploadedFile.new(Rails.root.join("public", "logo_bubble.png"), "image/png")
  end

  describe "POST /api/images (with an uploaded doc)" do
    it "records source_type User" do
      post "/api/images",
           params: { image: { label: "grandma", docs: { image: upload } } },
           headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(Doc.order(:id).last.source_type).to eq(Doc::SOURCE_TYPE_USER)
    end
  end

  describe "POST /api/images/:id/add_doc" do
    it "records source_type User" do
      post "/api/images/#{image.id}/add_doc",
           params: { image: { docs: { image: upload } } },
           headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(image.docs.reload.last.source_type).to eq(Doc::SOURCE_TYPE_USER)
    end
  end

  describe "POST /api/boards/:id/add_image (with an uploaded doc)" do
    let!(:board) { create(:board, user: user) }

    it "records source_type User" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "cup", docs: { image: upload } } },
           headers: auth_headers(user)

      expect(Doc.order(:id).last.source_type).to eq(Doc::SOURCE_TYPE_USER)
    end
  end

  # Api::DocsController#create also assigns SOURCE_TYPE_USER (only when blank, so
  # an explicit claim survives), but it is not covered here: its JSON branch
  # renders `location: @doc`, which needs a `doc_url` helper that does not exist
  # in the `api` namespace, so the response raises NoMethodError *after* the
  # save. That bug predates this change and no client calls the action — the
  # frontend only uses docs/:id/mark_as_current.

  describe "Doc.user_uploaded" do
    it "selects only user-uploaded docs" do
      mine   = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER)
      symbol = create(:doc, documentable: image, user: user, source_type: "OpenSymbol")

      expect(Doc.user_uploaded).to include(mine)
      expect(Doc.user_uploaded).not_to include(symbol)
    end
  end
end
