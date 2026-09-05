require "rails_helper"

# `/pb/<slug>` only resolves for a published board — `Board#viewable_by?` refuses
# an anonymous caller an unpublished one. Serializing `public_url` regardless
# handed the app a link, a QR code and a "send this to anyone" panel for a
# resource that 404s for every recipient (#860). The payload has to tell the
# truth about shareability.
#
# The prospective address still exists for the one caller that needs it before
# publication (the board-PDF QR) — see Boards::AssetRendering.qr_target_url_for.
RSpec.describe "API::Boards public_url", type: :request do
  let(:owner) { create(:user) }

  describe "Board#public_url" do
    it "is nil while the board is unpublished" do
      board = create(:board, user: owner, slug: "snack-time", published: false)

      expect(board.public_url).to be_nil
    end

    it "is the /pb/<slug> address once published" do
      board = create(:board, user: owner, slug: "snack-time", published: true)

      expect(board.public_url).to end_with("/pb/snack-time")
    end

    it "reappears on publish and disappears again on unpublish" do
      board = create(:board, user: owner, slug: "snack-time", published: false)

      board.update!(published: true)
      expect(board.public_url).to end_with("/pb/snack-time")

      board.update!(published: false)
      expect(board.public_url).to be_nil
    end
  end

  describe "Board#prospective_public_url" do
    it "is the address the board will live at, published or not" do
      unpublished = create(:board, user: owner, slug: "draft-board", published: false)
      published = create(:board, user: owner, slug: "shared-board", published: true)

      expect(unpublished.prospective_public_url).to end_with("/pb/draft-board")
      expect(published.prospective_public_url).to eq(published.public_url)
    end
  end

  describe "GET /api/boards/:id" do
    def show(board)
      get "/api/boards/#{board.id}", headers: auth_headers(owner)
      JSON.parse(response.body)
    end

    it "serves no share URL for an unpublished board" do
      board = create(:board, user: owner, slug: "snack-time", published: false)

      body = show(board)

      expect(response).to have_http_status(:ok)
      expect(body["published"]).to be(false)
      expect(body["public_url"]).to be_nil
    end

    it "serves the share URL once the board is published" do
      board = create(:board, user: owner, slug: "snack-time", published: true)

      body = show(board)

      expect(response).to have_http_status(:ok)
      expect(body["public_url"]).to end_with("/pb/snack-time")
    end
  end
end
