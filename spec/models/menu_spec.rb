require "rails_helper"

RSpec.describe Menu, type: :model do
  describe "#enhance_image_description" do
    let(:user) { FactoryBot.create(:user) }
    let(:menu) { FactoryBot.create(:menu, user: user, name: "Joe's Diner") }
    let(:board) do
      FactoryBot.create(:board, user: user, board_type: "menu",
                                parent_type: "Menu", parent_id: menu.id)
    end
    let(:vision_result) do
      { "menu_items" => [{ "name" => "cheeseburger",
                           "image_description" => "A cheeseburger." }] }
    end

    before do
      menu.docs.create!(user: user)
      allow_any_instance_of(MenuVisionService)
        .to receive(:extract_menu_items).and_return(vision_result)
      allow(menu).to receive(:menu_image_for_vision)
        .and_return("https://example.com/menu.jpg")
    end

    it "persists the vision result to the menu and its doc" do
      allow(menu).to receive(:create_board_from_menu_image)

      menu.enhance_image_description(board.id)

      expect(menu.reload.description).to eq(vision_result.to_json)
      expect(menu.docs.reload.last.processed).to eq(vision_result.to_json)
    end

    it "builds the board from the extracted menu items" do
      expect(menu).to receive(:create_board_from_menu_image)
        .with(an_instance_of(Doc), board.id)

      menu.enhance_image_description(board.id)
    end

    it "returns nil and skips board build when no menu image is available" do
      allow(menu).to receive(:menu_image_for_vision).and_return(nil)
      expect(menu).not_to receive(:create_board_from_menu_image)

      expect(menu.enhance_image_description(board.id)).to be_nil
    end

    it "returns nil when no board is found" do
      expect(menu.enhance_image_description(nil)).to be_nil
    end

    it "returns nil when the vision service extracts no items" do
      allow_any_instance_of(MenuVisionService)
        .to receive(:extract_menu_items).and_return({ "menu_items" => [] })
      expect(menu).not_to receive(:create_board_from_menu_image)

      expect(menu.enhance_image_description(board.id)).to be_nil
    end
  end
end
