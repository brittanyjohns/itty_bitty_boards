require "rails_helper"

# Regression: Board.upsert_board_image keyed the tile "upsert" on the resolved
# image_id, but find_or_create_image_for_button can resolve the SAME authored
# button to a different Image across re-imports (the OBF button's image_id
# changed, so the obf_id branch misses and the fallback picks a different
# label match). That forked a duplicate tile every time resolution drifted —
# how the Core 60 builder source grew a second "all done" word tile. The upsert
# is now keyed on the stable authored button id instead.
RSpec.describe "Board.from_obf re-import idempotency", type: :model do
  let(:user) { create(:user) }

  # Two same-label images. The OLDER one (lower id) is the fallback target when
  # the button's image_id no longer matches an obf_id — i.e. resolution drift.
  let!(:old_image) { create(:image, label: "all done", user_id: user.id, obf_id: "obf-old") }
  let!(:img_a)     { create(:image, label: "all done", user_id: user.id, obf_id: "img-a") }

  def obf(image_id:)
    {
      "id" => "core",
      "name" => "Core",
      "buttons" => [{ "id" => "b1", "label" => "all done", "image_id" => image_id }],
      "grid" => { "rows" => 1, "columns" => 1, "order" => [["b1"]] },
      "images" => [],
    }
  end

  it "resolves the button to its obf_id match on first import and stamps the button id" do
    board, = Board.from_obf(obf(image_id: "img-a"), user)

    expect(board.board_images.count).to eq(1)
    tile = board.board_images.first
    expect(tile.image_id).to eq(img_a.id)
    expect(tile.data["obf_button_id"]).to eq("b1")
  end

  it "updates the same tile instead of forking a duplicate when resolution drifts" do
    board, = Board.from_obf(obf(image_id: "img-a"), user)
    first_tile = board.board_images.first

    # The button's image_id changed: the obf_id branch misses and resolution
    # falls back to the oldest same-label image (old_image).
    board2, = Board.from_obf(obf(image_id: "changed"), user)

    expect(board2.id).to eq(board.id)
    expect(board2.board_images.count).to eq(1), "expected the drifted re-import to update the tile, not append a second 'all done'"

    tile = board2.board_images.first
    expect(tile.id).to eq(first_tile.id)
    expect(tile.image_id).to eq(old_image.id)
    expect(tile.data["obf_button_id"]).to eq("b1")
  end
end
