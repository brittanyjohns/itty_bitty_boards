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

  describe "#create_board_from_menu_image grid columns" do
    let(:user) { FactoryBot.create(:user) }
    let(:menu) { FactoryBot.create(:menu, user: user, name: "Joe's Diner") }
    let(:board) do
      FactoryBot.create(:board, user: user, board_type: "menu", large_screen_columns: 8,
                                medium_screen_columns: 6, small_screen_columns: 4,
                                parent_type: "Menu", parent_id: menu.id)
    end
    let(:doc) { menu.docs.create!(user: user, processed: { "menu_items" => [] }.to_json) }

    # Stand in for the real image build: the only thing the grid math cares
    # about is how many tiles the menu ended up with.
    def build_with_tiles(tile_count)
      allow(menu).to receive(:create_images_from_description) do |b|
        tile_count.times { FactoryBot.create(:board_image, board: b) }
      end
      menu.create_board_from_menu_image(doc, board.id)
      board.reload
    end

    it "sizes the grid to an exact square when the item count allows one" do
      build_with_tiles(16)

      expect(board.large_screen_columns).to eq(4)
      expect(board.rows_for_screen_size("lg")).to eq(4)
    end

    it "derives the medium and small counts from the large one" do
      build_with_tiles(16)

      expect(board.medium_screen_columns).to eq(Boards::ScreenColumns.derive(4, "md"))
      expect(board.small_screen_columns).to eq(Boards::ScreenColumns.derive(4, "sm"))
    end

    it "keeps number_of_columns in step with the grid the layout uses" do
      build_with_tiles(9)

      expect(board.large_screen_columns).to eq(3)
      expect(board.number_of_columns).to eq(board.get_number_of_columns("lg"))
    end

    it "lays every tile out inside the chosen width" do
      build_with_tiles(10)

      expect(board.large_screen_columns).to eq(4)
      expect(board.layout["lg"].map { |cell| cell["x"] }.max).to eq(3)
    end

    it "leaves the board's columns alone when no tiles were created" do
      build_with_tiles(0)

      expect(board.large_screen_columns).to eq(8)
    end
  end

  describe "#create_images_from_description image budget" do
    let(:user) { FactoryBot.create(:user) }
    let(:menu) { FactoryBot.create(:menu, user: user, token_limit: 10) }
    let(:board) do
      FactoryBot.create(:board, user: user, board_type: "menu", token_limit: 10,
                                parent_type: "Menu", parent_id: menu.id)
    end

    before do
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      txn = CreditService.spend!(user, feature_key: "menu_create", amount: 15)
      board.update!(settings: (board.settings || {}).merge(
        "menu_credit" => { "txn_id" => txn.id, "per_image" => 1, "reserved" => 10 },
      ))
      menu.update!(description: {
        "menu_items" => [
          { "name" => "cheeseburger", "image_description" => "A cheeseburger." },
          { "name" => "milkshake", "image_description" => "A milkshake." },
        ],
      }.to_json)
    end

    it "refunds the budget it did not use" do
      # 2 novel items get queued out of a 10-image budget: 8 credits back.
      expect {
        menu.create_images_from_description(board)
      }.to change { user.reload.plan_credits_balance }.by(8)
    end

    it "caps generation at the board's token_limit" do
      board.update!(token_limit: 1)

      expect {
        menu.create_images_from_description(board)
      }.to change { user.reload.plan_credits_balance }.by(9)

      expect(board.board_images.where(status: "skipped").count).to eq(1)
    end

    it "generates fresh menu images with description-driven prompts" do
      menu.create_images_from_description(board)

      img = board.images.find_by(label: "cheeseburger")
      expect(img.image_type).to eq("menu")
      expect(img.is_private).to be(true)
      expect(img.user_id).to eq(user.id)
      expect(img.image_prompt).to include("A cheeseburger.")
      expect(img.image_prompt).to include(Menu::PROMPT_ADDITION)
    end

    it "refunds the whole image budget when the build raises" do
      allow(board).to receive(:find_or_create_images_from_word_list).and_raise("boom")

      expect {
        menu.create_images_from_description(board)
      }.to change { user.reload.plan_credits_balance }.by(10)
    end
  end
end
