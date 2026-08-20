require "rails_helper"

# Images and Docs are SHARED library rows; board_images.display_image_url is
# per-tile user content on one user's board. Marking a doc "current" used to
# write images.src_url, whose after_save swept EVERY board_image of that Image
# across every account — so admin picking different library art repainted
# every user's board.
RSpec.describe "POST /api/docs/:id/mark_as_current — board isolation", type: :request do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let!(:stranger) { create(:user) }

  # A shared library image owned by admin, as the real ones are.
  let!(:image) { create(:image, user: admin, label: "apple", is_private: false) }
  let!(:old_doc) { create(:doc, documentable: image, user: admin, current: true) }
  let!(:new_doc) { create(:doc, documentable: image, user: admin) }

  let!(:admin_board) { create(:board, user: admin) }
  let!(:stranger_board) { create(:board, user: stranger) }

  let(:old_url) { "https://cdn.example.com/old.webp" }
  let(:new_url) { "https://cdn.example.com/new.webp" }

  before do
    allow_any_instance_of(Doc).to receive(:tile_url) do |doc|
      doc.id == new_doc.id ? new_url : old_url
    end
    image.update_columns(src_url: old_url)

    [admin_board, stranger_board].each { |b| b.add_image(image.id) }
    image.board_images.reset
  end

  def tile_on(board)
    image.board_images.find_by(board_id: board.id)
  end

  def set_tile(board, url)
    tile_on(board).update_column(:display_image_url, url)
  end

  context "when the admin marks a different doc current" do
    it "leaves a stranger's tile that was tracking the old default alone" do
      set_tile(stranger_board, old_url)

      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(tile_on(stranger_board).reload.display_image_url).to eq(old_url)
    end

    it "leaves a stranger's empty tile alone" do
      set_tile(stranger_board, nil)

      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(admin)

      expect(tile_on(stranger_board).reload.display_image_url).to be_nil
    end

    it "leaves a stranger's hidden tile hidden" do
      set_tile(stranger_board, "")

      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(admin)

      expect(tile_on(stranger_board).reload.display_image_url).to eq("")
    end

    it "does not reach a stranger's board even with update_all" do
      set_tile(stranger_board, old_url)

      post "/api/docs/#{new_doc.id}/mark_as_current",
           params: { update_all: true }.to_json,
           headers: auth_headers(admin).merge("CONTENT_TYPE" => "application/json")

      expect(tile_on(stranger_board).reload.display_image_url).to eq(old_url)
    end

    it "still updates the admin's own tile" do
      set_tile(admin_board, old_url)

      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(admin)

      expect(tile_on(admin_board).reload.display_image_url).to eq(new_url)
    end

    # src_url is what BoardImage#set_defaults snapshots, so it is how a library
    # change legitimately reaches FUTURE boards. It must still move.
    it "moves the library default so new tiles pick it up" do
      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(admin)

      expect(image.reload.src_url).to eq(new_url)
      expect(new_doc.reload.current).to be(true)
      expect(old_doc.reload.current).to be(false)
    end
  end

  context "when a non-admin marks a doc current" do
    it "does not move the shared library default" do
      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(stranger)

      expect(response).to have_http_status(:ok)
      expect(new_doc.reload.current).to be(false)
      expect(image.reload.src_url).to eq(old_url)
    end

    it "records their own pick as a UserDoc" do
      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(stranger)

      expect(UserDoc.find_by(user_id: stranger.id, image_id: image.id)&.doc_id).to eq(new_doc.id)
    end

    it "pins the tile on their own board" do
      post "/api/docs/#{new_doc.id}/mark_as_current",
           params: { board_id: stranger_board.id }.to_json,
           headers: auth_headers(stranger).merge("CONTENT_TYPE" => "application/json")

      expect(tile_on(stranger_board).reload.display_image_url).to eq(new_url)
    end

    it "does not touch the admin's tile" do
      set_tile(admin_board, old_url)

      post "/api/docs/#{new_doc.id}/mark_as_current", headers: auth_headers(stranger)

      expect(tile_on(admin_board).reload.display_image_url).to eq(old_url)
    end
  end

  # The board_id was looked up with an unscoped find_by, so anyone could
  # repaint a tile on any board by passing its id.
  it "refuses to pin a tile on a board the caller cannot edit" do
    other = create(:user)
    set_tile(stranger_board, old_url)

    post "/api/docs/#{new_doc.id}/mark_as_current",
         params: { board_id: stranger_board.id }.to_json,
         headers: auth_headers(other).merge("CONTENT_TYPE" => "application/json")

    expect(tile_on(stranger_board).reload.display_image_url).to eq(old_url)
  end
end
