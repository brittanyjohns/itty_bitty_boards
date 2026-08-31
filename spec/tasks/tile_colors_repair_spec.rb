require "rails_helper"
require "rake"

RSpec.describe "tile_colors:repair" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tile_colors:repair")
  end

  let(:user) { create(:user) }

  describe "TileColorRepair.repair_for" do
    it "repaints a tile whose color drifted from its category" do
      board = create(:board, user: user)
      image = create(:image, label: "my turn", user: user)
      image.update!(part_of_speech: "social")
      tile = board.board_images.create!(image: image)
      tile.update_columns(bg_color: "#FFC457")

      expect(TileColorRepair.repair_for(tile.reload)).to include(bg_color: "#FF99B8")
    end

    # White is in PRESET_HEX, so `authored?` lets a menu tile through — without
    # the resolver the repair would repaint every menu board from its category.
    it "leaves a white tile on a menu board alone" do
      menu_board = create(:board, user: user, board_type: "menu")
      image = create(:image, label: "virginia", user: user)
      image.update!(part_of_speech: "noun")
      tile = menu_board.board_images.create!(image: image)

      expect(tile.reload.bg_color).to eq("#FFFFFF")
      expect(TileColorRepair.repair_for(tile)).to be_nil
    end

    it "leaves a white menu image alone" do
      menu_image = create(:image, label: "single", user: user, image_type: "menu")

      expect(TileColorRepair.repair_for(menu_image.reload)).to be_nil
    end
  end
end
