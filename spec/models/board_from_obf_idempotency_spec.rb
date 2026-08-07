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

  # OBF buttons are authored with display casing ("Food"), while images store
  # the lowercase matching key. The import's own image cache queried and keyed
  # on the RAW button label, so every capitalised button missed and fell through
  # to Image.create! — minting a fresh duplicate on each import.
  describe "capitalised button labels" do
    def capitalised_obf
      {
        "id" => "core", "name" => "Core",
        "buttons" => [{ "id" => "b1", "label" => "Food", "image_id" => nil }],
        "grid" => { "rows" => 1, "columns" => 1, "order" => [["b1"]] },
        "images" => [],
      }
    end

    # Counts images for the BUTTON's label specifically — from_obf also creates
    # an image for the board's own name, which is not what these guard.
    it "resolves a capitalised button to the existing lowercase image" do
      existing = create(:image, label: "Food", user_id: user.id)
      expect(existing.label).to eq("food")

      expect { Board.from_obf(capitalised_obf, user) }
        .not_to change { Image.by_label("Food").count }

      board = user.boards.find_by(obf_id: "core")
      expect(board.board_images.first.image_id).to eq(existing.id)
    end

    it "does not mint a new image for the button on every re-import" do
      Board.from_obf(capitalised_obf, user)
      expect(Image.by_label("Food").count).to eq(1)

      Board.from_obf(capitalised_obf, user)
      expect(Image.by_label("Food").count).to eq(1)
    end
  end

  # Core 60/84 author both a "more" word tile and a "More" category folder.
  # Case-insensitive image lookup makes them share ONE Image, and the legacy
  # by_image_id adoption path then handed the folder's tile to the word button —
  # the seeded home boards came out 58/82 tiles instead of 60/84.
  it "gives two authored buttons their own tiles even when they share an Image" do
    shared = create(:image, label: "more", user_id: user.id)

    data = {
      "id" => "core", "name" => "Core",
      "buttons" => [
        { "id" => "word",   "label" => "more" },
        { "id" => "folder", "label" => "More" },
      ],
      "grid" => { "rows" => 1, "columns" => 2, "order" => [%w[word folder]] },
      "images" => [],
    }

    board, = Board.from_obf(data, user)

    expect(board.board_images.count).to eq(2), "the word tile and the folder tile must both survive"
    expect(board.board_images.map { |bi| bi.data["obf_button_id"] }).to contain_exactly("word", "folder")
    expect(board.board_images.map(&:image_id).uniq).to eq([shared.id])
  end

  # Both buttons share one Image, so whichever was imported first would
  # otherwise decide that Image's display casing for both tiles — which is how
  # the Core 84 "More" and "Play" folders came out rendering as "more"/"play".
  it "keeps each button's authored casing even when both share an Image" do
    create(:image, label: "more", user_id: user.id)

    data = {
      "id" => "core", "name" => "Core",
      "buttons" => [
        { "id" => "word",   "label" => "more" },
        { "id" => "folder", "label" => "More" },
      ],
      "grid" => { "rows" => 1, "columns" => 2, "order" => [%w[word folder]] },
      "images" => [],
    }

    board, = Board.from_obf(data, user)
    by_button = board.board_images.index_by { |bi| bi.data["obf_button_id"] }

    expect(by_button["word"].display_label).to eq("more")
    expect(by_button["folder"].display_label).to eq("More")
    # ...while the matching key stays lowercase on both.
    expect(by_button.values.map(&:label).uniq).to eq(["more"])
  end
end
