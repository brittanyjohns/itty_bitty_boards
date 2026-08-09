# spec/requests/api/images_label_casing_spec.rb
#
# The normal (non-internal) API paths for adding an image / building a board
# used to look images up with a case-sensitive `find_by(label:)`. A user typing
# "Swing" sailed past the curated `swing` symbol, and the calling site's very
# next line created a blank, art-less Image beside it — a duplicate in the
# library and an empty tile on the board.
#
# The internal API was fixed for this in #573 via Boards::ImageResolver; these
# cover the same guarantee on the paths the app itself uses.

require "rails_helper"

RSpec.describe "Images label casing", type: :request do
  def j
    JSON.parse(response.body)
  rescue
    {}
  end

  before do
    allow_any_instance_of(API::ApplicationController)
      .to receive(:authenticate_token!).and_return(true)
    allow_any_instance_of(API::ApplicationController)
      .to receive(:current_user).and_return(user)
  end

  let!(:user) { create(:user) }

  # The curated library symbol: lowercase matching key, artwork attached.
  let!(:curated) do
    create(:image, label: "swing", user_id: nil, private: false).tap do |img|
      create(:doc, documentable: img, processed: "img")
    end
  end

  describe "POST /api/images/find_or_create" do
    it "reuses the curated image when the caller types a different casing" do
      expect {
        post "/api/images/find_or_create", params: { image: { label: "Swing" } }
      }.not_to change(Image, :count)

      expect(response).to have_http_status(:ok)
      expect(j["id"]).to eq(curated.id)
    end

    it "reuses the curated image when the caller sends stray whitespace" do
      expect {
        post "/api/images/find_or_create", params: { image: { label: "  swing  " } }
      }.not_to change(Image, :count)

      expect(j["id"]).to eq(curated.id)
    end

    it "still creates an image for a genuinely new word" do
      expect {
        post "/api/images/find_or_create", params: { image: { label: "Trampoline" } }
      }.to change(Image, :count).by(1)

      created = Image.by_label("trampoline").first
      expect(created.label).to eq("trampoline")
      # The capital a user happens to type carries no intent, so it is folded to
      # the lowercase AAC default rather than becoming this word's permanent
      # display text. Deliberate casing survives — see the "iPad" examples in
      # spec/services/labels/case_normalizer_spec.rb.
      expect(created.display_label).to eq("trampoline")
    end
  end

  describe "POST /api/boards/:id/add_image" do
    let!(:board) { create(:board, user: user, language: "en") }

    it "attaches the curated image rather than minting a cased duplicate" do
      expect {
        post "/api/boards/#{board.id}/add_image", params: { image: { label: "Swing" } }
      }.not_to change(Image, :count)

      tile = board.board_images.reload.last
      expect(tile.image_id).to eq(curated.id)
    end

    it "gives the tile the lowercase matching key and normalized display text" do
      post "/api/boards/#{board.id}/add_image", params: { image: { label: "Swing" } }

      tile = board.board_images.reload.last
      expect(tile.label).to eq("swing")
      expect(tile.display_label).to eq("swing")
    end

    it "carries deliberate casing from the image onto the tile" do
      create(:image, label: "iPad", user_id: nil, private: false)

      post "/api/boards/#{board.id}/add_image", params: { image: { label: "ipad" } }

      tile = board.board_images.reload.last
      expect(tile.label).to eq("ipad")
      expect(tile.display_label).to eq("iPad")
    end
  end

  describe "GET /api/images/find_by_label" do
    it "finds the image regardless of the casing asked for" do
      get "/api/images/find_by_label", params: { label: "SWING" }

      expect(j["id"]).to eq(curated.id)
    end
  end
end
