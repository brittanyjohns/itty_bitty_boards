require "rails_helper"

# "Use board preview" is an explicit per-tile toggle: while it is on, a tile
# that links to another board shows that board's rendered preview.
RSpec.describe "BoardImage#linked_board_preview_url", type: :model do
  let(:user)        { FactoryBot.create(:user) }
  let(:board)       { FactoryBot.create(:board, user: user, name: "Home") }
  let(:target)      { FactoryBot.create(:board, user: user, name: "Food") }
  let(:image)       { FactoryBot.create(:image, label: "food") }
  let(:preview_url) { "https://cdn.example.test/previews/food.png" }
  let(:tile_art)    { "https://cdn.example.test/library/food.png" }

  let!(:door) do
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: target.id,
                                    data: { "mute_name" => true, "use_board_preview" => true })
  end

  before do
    door.update_column(:display_image_url, tile_art)
    # The rendered preview is an ActiveStorage attachment. Stub its URL for the
    # linked board only, so nothing is uploaded and every other board keeps the
    # real (unattached, nil) answer.
    target_id = target.id
    url = preview_url
    allow_any_instance_of(Board).to receive(:preview_image_url).and_wrap_original do |original|
      original.receiver.id == target_id ? url : original.call
    end
  end

  describe "the helper" do
    it "returns the linked board's preview while the toggle is on" do
      expect(door.reload.linked_board_preview_url).to eq(preview_url)
    end

    it "returns nil when the toggle was never set" do
      door.update_column(:data, { "mute_name" => true })
      expect(door.reload.linked_board_preview_url).to be_nil
    end

    it "returns nil when the toggle is switched off" do
      door.update_column(:data, { "mute_name" => true, "use_board_preview" => false })
      expect(door.reload.linked_board_preview_url).to be_nil
    end

    it "wins over a picture someone chose, because it is an explicit choice" do
      door.update_column(:display_image_url, "https://cdn.example.test/uploads/my-food.png")
      expect(door.reload.linked_board_preview_url).to eq(preview_url)
    end

    it "keeps a deliberately blank tile blank" do
      door.update_column(:display_image_url, "")
      expect(door.reload.linked_board_preview_url).to be_nil
    end

    it "uses the rendered preview, never the linked board's custom cover" do
      target.update_columns(settings: { "display_image_source" => "custom" },
                            display_image_url: "https://cdn.example.test/covers/food.png")
      expect(door.reload.linked_board_preview_url).to eq(preview_url)
    end

    it "leaves the tile's own art when the linked board has no rendered preview" do
      unrendered = FactoryBot.create(:board, user: user, name: "Play")
      door.update_column(:predictive_board_id, unrendered.id)
      expect(door.reload.linked_board_preview_url).to be_nil
    end

    it "ignores a tile that links to its own board" do
      door.update_column(:predictive_board_id, board.id)
      expect(door.reload.linked_board_preview_url).to be_nil
    end
  end

  describe "the tile serializers" do
    def tile_src(images)
      images.find { |i| i[:board_image_id] == door.id.to_s }[:src]
    end

    it "serves the preview in the editor payload, and the tile's own art once switched off" do
      expect(tile_src(board.reload.api_view_with_predictive_images(user)[:images])).to eq(preview_url)

      door.update_column(:data, { "mute_name" => true, "use_board_preview" => false })
      expect(tile_src(board.reload.api_view_with_predictive_images(user)[:images])).to eq(tile_art)
    end

    it "serves the preview in the Speak payload, and the tile's own art once switched off" do
      expect(tile_src(board.reload.api_view_for_native_grid(user)[:images])).to eq(preview_url)

      door.update_column(:data, { "mute_name" => true })
      expect(tile_src(board.reload.api_view_for_native_grid(user)[:images])).to eq(tile_art)
    end
  end
end
