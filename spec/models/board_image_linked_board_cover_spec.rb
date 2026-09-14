require "rails_helper"

# A folder tile shows the cover of the board it opens, resolved at read time,
# but only while the tile's own picture is nil or still the library default.
RSpec.describe "BoardImage#linked_board_cover_url", type: :model do
  let(:user)      { FactoryBot.create(:user) }
  let(:board)     { FactoryBot.create(:board, user: user, name: "Home") }
  let(:target)    { FactoryBot.create(:board, user: user, name: "Food") }
  let(:image)     { FactoryBot.create(:image, label: "food") }
  let(:cover_url) { "https://cdn.example.test/covers/food.png" }
  let(:library)   { "https://cdn.example.test/library/food.png" }

  let!(:door) do
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: target.id,
                                    data: { "mute_name" => true })
  end

  before do
    # Custom cover mode reads the column, so no ActiveStorage is involved.
    target.update_columns(settings: { "display_image_source" => "custom" }, display_image_url: cover_url)
    image.update_column(:src_url, library)
    door.update_column(:display_image_url, library)
  end

  describe "the helper" do
    it "returns the linked board's cover while the tile is on library-default art" do
      expect(door.reload.linked_board_cover_url).to eq(cover_url)
    end

    it "returns the cover when the tile has no picture at all" do
      door.update_column(:display_image_url, nil)
      expect(door.reload.linked_board_cover_url).to eq(cover_url)
    end

    it "keeps a picture someone chose" do
      door.update_column(:display_image_url, "https://cdn.example.test/uploads/my-food.png")
      expect(door.reload.linked_board_cover_url).to be_nil
    end

    it "keeps a deliberately blank tile blank" do
      door.update_column(:display_image_url, "")
      expect(door.reload.linked_board_cover_url).to be_nil
    end

    it "leaves a predictive word tile on its own picture" do
      target.update_column(:board_type, "predictive")
      word_tile = FactoryBot.create(:board_image, board: board, image: FactoryBot.create(:image),
                                                  predictive_board_id: target.id)
      expect(word_tile.reload.linked_board_cover_url).to be_nil
    end

    it "falls back to the tile's art when the linked board has no cover" do
      target.update_columns(settings: {}, display_image_url: nil)
      expect(door.reload.linked_board_cover_url).to be_nil
    end

    it "ignores a tile that links to its own board" do
      door.update_column(:predictive_board_id, board.id)
      expect(door.reload.linked_board_cover_url).to be_nil
    end
  end

  describe "the tile serializers" do
    let!(:plain) do
      tile = FactoryBot.create(:board_image, board: board, image: FactoryBot.create(:image, label: "apple"))
      tile.update_column(:display_image_url, "https://cdn.example.test/library/apple.png")
      tile
    end

    def tile_src(images, tile)
      images.find { |i| i[:board_image_id] == tile.id.to_s }[:src]
    end

    it "shows the cover on a folder tile in the editor payload, and leaves a plain tile alone" do
      images = board.reload.api_view_with_predictive_images(user)[:images]

      expect(tile_src(images, door)).to eq(cover_url)
      expect(tile_src(images, plain)).to eq("https://cdn.example.test/library/apple.png")
    end

    it "shows the cover on a folder tile in the Speak payload, and leaves a plain tile alone" do
      images = board.reload.api_view_for_native_grid(user)[:images]

      expect(tile_src(images, door)).to eq(cover_url)
      expect(tile_src(images, plain)).to eq("https://cdn.example.test/library/apple.png")
    end
  end
end
