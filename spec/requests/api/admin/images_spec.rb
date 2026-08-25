require "rails_helper"

# The admin library-curation surface: pin the default picture for a word, and
# purge a doc from the shared library.
RSpec.describe "API::Admin::Images", type: :request do
  let!(:admin) { create(:admin_user) }
  let!(:user)  { create(:user) }

  # A library image: shared, owned by nobody.
  let!(:image) { create(:image, label: "wagon", user_id: nil) }
  # original_image_url so Doc#tile_url returns a real URL — without it every
  # tile_url is nil and the src_url assertions below pass trivially.
  let!(:doc_a) { create(:doc, documentable: image, user_id: nil, original_image_url: "https://cdn.example.com/a.webp") }
  let!(:doc_b) { create(:doc, documentable: image, user_id: nil, original_image_url: "https://cdn.example.com/b.webp") }

  describe "the gate" do
    it "rejects an unauthenticated caller" do
      get "/api/admin/images/#{image.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a signed-in non-admin" do
      post "/api/admin/images/#{image.id}/set_default_doc",
           params: { doc_id: doc_b.id }, headers: auth_headers(user)

      expect(response).to have_http_status(:unauthorized)
      expect(doc_b.reload.current).to be(false)
    end

    it "is gated by inheritance, not an inline check" do
      expect(API::Admin::ImagesController.ancestors).to include(API::Admin::ApplicationController)
    end
  end

  describe "GET show" do
    it "lists the docs and marks which is the library default" do
      image.set_library_default_doc!(doc_b, actor: admin)

      get "/api/admin/images/#{image.id}", headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body["image"]["default_doc_id"]).to eq(doc_b.id)
      expect(body["image"]["is_library_image"]).to be(true)
      expect(body["docs"].map { |d| d["id"] }).to match_array([doc_a.id, doc_b.id])
      expect(body["docs"].find { |d| d["id"] == doc_b.id }["is_current"]).to be(true)
    end

    it "shows soft-deleted docs so they can be purged" do
      doc_a.hide!

      get "/api/admin/images/#{image.id}", headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(body["docs"].map { |d| d["id"] }).to include(doc_a.id)
      expect(body["docs"].find { |d| d["id"] == doc_a.id }["deleted_at"]).to be_present
    end
  end

  describe "POST set_default_doc" do
    it "moves both halves of the default — docs.current and src_url" do
      post "/api/admin/images/#{image.id}/set_default_doc",
           params: { doc_id: doc_b.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(doc_b.reload.current).to be(true)
      expect(image.reload.src_url).to eq("https://cdn.example.com/b.webp")
    end

    it "leaves exactly one current doc behind" do
      image.set_library_default_doc!(doc_a, actor: admin)

      post "/api/admin/images/#{image.id}/set_default_doc",
           params: { doc_id: doc_b.id }, headers: auth_headers(admin)

      expect(image.reload.docs.where(current: true).pluck(:id)).to eq([doc_b.id])
    end

    it "refuses a doc belonging to a different image" do
      other = create(:doc, documentable: create(:image), user_id: nil, original_image_url: "https://cdn.example.com/other.webp")

      post "/api/admin/images/#{image.id}/set_default_doc",
           params: { doc_id: other.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "does not repaint a tile the owner gave its own picture" do
      board = create(:board, user: user)
      tile = create(:board_image, board: board, image: image)
      tile.update_column(:display_image_url, "https://cdn.example.com/mine.webp")

      post "/api/admin/images/#{image.id}/set_default_doc",
           params: { doc_id: doc_b.id }, headers: auth_headers(admin)

      expect(tile.reload.display_image_url).to eq("https://cdn.example.com/mine.webp")
    end

    it "does not un-hide a tile whose picture was deliberately switched off" do
      board = create(:board, user: user)
      tile = create(:board_image, board: board, image: image)
      tile.update_column(:display_image_url, "")

      post "/api/admin/images/#{image.id}/set_default_doc",
           params: { doc_id: doc_b.id }, headers: auth_headers(admin)

      expect(tile.reload.display_image_url).to eq("")
    end
  end

  describe "DELETE default_doc" do
    it "unpins without leaving src_url blank" do
      image.set_library_default_doc!(doc_b, actor: admin)

      delete "/api/admin/images/#{image.id}/default_doc", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(image.reload.docs.where(current: true)).to be_empty
      expect(image.reload.src_url).to be_present
    end
  end

  describe "DELETE a doc" do
    it "permanently removes it, unlike the user-facing hide" do
      delete "/api/admin/images/#{image.id}/docs/#{doc_a.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(Doc.unscoped.find_by(id: doc_a.id)).to be_nil
    end

    it "purges an already-hidden doc" do
      doc_a.hide!

      delete "/api/admin/images/#{image.id}/docs/#{doc_a.id}", headers: auth_headers(admin)

      expect(Doc.unscoped.find_by(id: doc_a.id)).to be_nil
    end

    it "re-resolves the default when the deleted doc was it" do
      image.set_library_default_doc!(doc_b, actor: admin)
      image.update(src_url: doc_b.tile_url)

      delete "/api/admin/images/#{image.id}/docs/#{doc_b.id}", headers: auth_headers(admin)

      expect(image.reload.src_url).to eq("https://cdn.example.com/a.webp")
    end

    it "refuses a doc that belongs to another image" do
      other = create(:doc, documentable: create(:image), user_id: nil, original_image_url: "https://cdn.example.com/other.webp")

      delete "/api/admin/images/#{image.id}/docs/#{other.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(Doc.unscoped.find_by(id: other.id)).to be_present
    end
  end
end
