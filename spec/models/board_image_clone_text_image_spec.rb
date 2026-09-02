require "rails_helper"

# A text tile is a rendered PNG of typed text (data["text_image"] + a Doc URL in
# display_image_url). Cloning replaced that URL with the shared Image's library
# symbol while data["text_image"] still claimed a render, so a copied board
# showed a picture the owner had deliberately replaced with words.
RSpec.describe "Cloning a board keeps its text tiles" do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:owner) { create(:user) }
  let(:other_user) { create(:user) }
  let(:image) { create(:image, user: owner, label: "more") }
  let(:board) { create(:board, user: owner, name: "Core") }
  let(:board_image) { create(:board_image, board: board, image: image) }
  let(:options) { Images::TextTile::Options.from_params(text: "more", font: "atkinson", hide_label: "true") }

  # A 1x1 PNG — enough for Active Storage to attach and for vips to variant.
  let(:png) do
    Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    )
  end

  before do
    allow_any_instance_of(Images::TextTile::Renderer).to receive(:to_png).and_return(png)
    image.update_columns(src_url: "https://cdn.example.com/more-symbol.webp")
  end

  let!(:doc) { Images::TextTile::Creator.call(board_image: board_image, user: owner, options: options) }

  def cloned_tile(cloned)
    cloned.reload.board_images.first
  end

  it "shows the rendered text, not the library symbol" do
    tile = cloned_tile(board.reload.clone_with_images(owner.id, "Core copy"))

    expect(tile.display_image_url).to eq(doc.tile_url)
    expect(tile.display_image_url).not_to eq(image.src_url)
  end

  it "keeps the render options and hide_label so the editor can restore them" do
    tile = cloned_tile(board.reload.clone_with_images(owner.id, "Core copy 2"))

    expect(tile.data["text_image"]).to include(options.to_h.stringify_keys)
    expect(tile.data["hide_label"]).to be(true)
  end

  # The Doc hangs off the SOURCE tile's Image, so it never shows up in the
  # clone's own gallery and #unchanged_render? would skip re-renders forever on
  # the strength of another account's row.
  it "drops the stale text-tile doc pointer" do
    tile = cloned_tile(board.reload.clone_with_images(owner.id, "Core copy 3"))

    expect(tile.data["text_image"]).not_to have_key("doc_id")
    expect(board_image.reload.data.dig("text_image", "doc_id")).to eq(doc.id)
  end

  it "survives a cross-user clone, where the tile re-resolves to another image" do
    tile = cloned_tile(board.reload.clone_with_images(other_user.id, "Core copy 4"))

    expect(tile.display_image_url).to eq(doc.tile_url)
  end
end
