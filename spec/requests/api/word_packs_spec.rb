require "rails_helper"

RSpec.describe "API::WordPacks", type: :request do
  let!(:user) { create(:user) }
  let!(:board) { create(:board, user: user) }

  def json = JSON.parse(response.body)

  def pack(key) = json["packs"].find { |p| p["key"] == key }

  it "requires authentication" do
    get "/api/word_packs"
    expect(response).to have_http_status(:unauthorized)
  end

  it "serves every pack with its words" do
    get "/api/word_packs", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(json["packs"].map { |p| p["key"] })
      .to eq(%w[pronouns actions social numbers sizes condiments ordering])
    expect(pack("pronouns")["words"].map { |w| w["label"] }).to include("he", "she", "they")
  end

  # Sizes, condiments and ordering were menu-only, which put them out of reach
  # of the ordinary board someone builds for a cafe visit. Same catalog on every
  # board now, board_id or not.
  it "offers the sizes, condiments and ordering packs off a menu board too" do
    menu_board = create(:board, user: user, board_type: "menu")

    get "/api/word_packs", params: { board_id: board.id }, headers: auth_headers(user)
    expect(json["packs"].map { |p| p["key"] }).to include("sizes", "condiments", "ordering")
    expect(pack("ordering")["words"].map { |w| w["label"] }).to include("Can I have")

    get "/api/word_packs", params: { board_id: menu_board.id }, headers: auth_headers(user)
    expect(json["packs"].map { |p| p["key"] }).to include("sizes", "condiments", "ordering")
  end

  it "flags the words already on the board" do
    image = create(:image, label: "he")
    board.add_image(image.id)

    get "/api/word_packs", params: { board_id: board.id }, headers: auth_headers(user)

    words = pack("pronouns")["words"].index_by { |w| w["label"] }
    expect(words["he"]["on_board"]).to be(true)
    expect(words["she"]["on_board"]).to be(false)
  end

  # Reads the tiles, not the cached data["current_word_list"], which nothing
  # invalidates on delete — otherwise the picker greys out a word the user
  # removed and the add then skips it, with no way back.
  it "stops flagging a word once its tile is deleted" do
    image = create(:image, label: "he")
    board.add_image(image.id)
    board.reload.board_images.each(&:destroy)

    get "/api/word_packs", params: { board_id: board.id }, headers: auth_headers(user)

    words = pack("pronouns")["words"].index_by { |w| w["label"] }
    expect(words["he"]["on_board"]).to be(false)
  end

  it "returns the library art for a word that has some, and nil for one that doesn't" do
    arted = create(:image, label: "she", user_id: User::DEFAULT_ADMIN_ID, is_private: false)
    create(:doc, documentable: arted, user_id: User::DEFAULT_ADMIN_ID)
    arted.update!(src_url: "https://cdn.example.com/she.webp")

    get "/api/word_packs", headers: auth_headers(user)

    words = pack("pronouns")["words"].index_by { |w| w["label"] }
    expect(words["she"]["src"]).to eq("https://cdn.example.com/she.webp")
    expect(words["them"]["src"]).to be_nil
  end

  # The catalog fires on every open of the Add-tiles modal. Creating an Image
  # there would seed the shared library with blank rows just because someone
  # looked at the picker — which is why it uses ImageResolver.arted_all_for
  # (read-only) rather than resolve_all.
  it "creates nothing and generates nothing" do
    allow(GenerateImagesJob).to receive(:perform_async)

    expect {
      get "/api/word_packs", params: { board_id: board.id }, headers: auth_headers(user)
    }.to not_change(Image, :count).and not_change(BoardImage, :count)

    expect(GenerateImagesJob).not_to have_received(:perform_async)
    expect(response).to have_http_status(:ok)
  end

  # Treated as "no board", not 404'd. The catalog is the same either way, so the
  # observable half is `on_board`: a tile on someone else's board must not be
  # reported as placed on yours.
  it "ignores a board belonging to someone else rather than leaking its existence" do
    other_board = create(:board, user: create(:user))
    other_board.add_image(create(:image, label: "he").id)

    get "/api/word_packs", params: { board_id: other_board.id }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    words = pack("pronouns")["words"].index_by { |w| w["label"] }
    expect(words["he"]["on_board"]).to be(false)
  end
end
