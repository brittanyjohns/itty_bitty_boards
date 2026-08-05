require "rails_helper"

RSpec.describe BoardImage, "tile colors" do
  let(:board) { FactoryBot.create(:board) }
  let(:image) { FactoryBot.create(:image, label: "my turn") }
  let(:board_image) { FactoryBot.create(:board_image, board: board, image: image) }

  before { image.update!(part_of_speech: "social") }

  describe "#effective_part_of_speech" do
    it "treats the stored 'default' placeholder as unset and inherits the Image's category" do
      board_image.update_columns(part_of_speech: "default")

      expect(board_image.reload.effective_part_of_speech).to eq("social")
    end

    it "keeps a per-board override" do
      board_image.update_columns(part_of_speech: "noun")

      expect(board_image.reload.effective_part_of_speech).to eq("noun")
    end

    it "falls back to 'default' when neither carries a category" do
      image.update_columns(part_of_speech: nil)
      board_image.update_columns(part_of_speech: "default")

      expect(board_image.reload.effective_part_of_speech).to eq("default")
    end
  end

  describe "#set_colors" do
    it "colors a 'default' tile from its Image's category instead of grey" do
      board_image.update_columns(part_of_speech: "default", bg_color: "#D1D1D1")

      board_image.reload.set_colors!

      expect(board_image.reload.bg_color).to eq("#FF99B8")
    end

    it "colors from the tile's own category when it overrides the Image's" do
      board_image.update_columns(part_of_speech: "noun", bg_color: "#D1D1D1")

      board_image.reload.set_colors!

      expect(board_image.reload.bg_color).to eq("#FFC457")
    end
  end
end
