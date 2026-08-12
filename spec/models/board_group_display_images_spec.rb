require "rails_helper"

RSpec.describe "board set display images" do
  let(:user) { create(:user) }

  def add_tile(board, label:, src: nil, links_to: nil)
    image = create(:image, label: label)
    bi = create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
    bi.update_column(:display_image_url, src) if src
    bi
  end

  describe "Board#seed_display_image_from_tiles!" do
    it "seeds the column from the first tile that resolves an image" do
      board = create(:board, user: user)
      add_tile(board, label: "apple", src: "https://cdn.example.com/apple.png")

      expect(board.seed_display_image_from_tiles!).to be(true)
      expect(board.reload.display_image_url).to eq("https://cdn.example.com/apple.png")
    end

    it "leaves a board that already has an image alone" do
      board = create(:board, user: user, display_image_url: "https://cdn.example.com/chosen.png")
      add_tile(board, label: "apple", src: "https://cdn.example.com/apple.png")

      expect(board.seed_display_image_from_tiles!).to be(false)
      expect(board.reload.display_image_url).to eq("https://cdn.example.com/chosen.png")
    end

    it "is a no-op for a board with no tiles" do
      board = create(:board, user: user)

      expect(board.seed_display_image_from_tiles!).to be(false)
      expect(board.reload.display_image_url).to be_blank
    end
  end

  describe "BoardGroup#seed_display_images!" do
    it "gives a sub-board the folder tile that opens it, not its own first tile" do
      home = create(:board, user: user, name: "Home")
      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "Food", src: "https://cdn.example.com/folder.png", links_to: food)
      add_tile(food, label: "apple", src: "https://cdn.example.com/apple.png")

      group = BoardGroup.create!(user: user, name: "Set")
      group.add_board(home)
      group.add_board(food)
      group.update!(root_board_id: home.id)

      group.reload.seed_display_images!

      expect(food.reload.display_image_url).to eq("https://cdn.example.com/folder.png")
    end

    it "seeds every member board and pins the set cover by reference" do
      home = create(:board, user: user, name: "Home")
      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "food", src: "https://cdn.example.com/food.png")
      add_tile(food, label: "apple", src: "https://cdn.example.com/apple.png")

      group = BoardGroup.create!(user: user, name: "Set")
      group.add_board(home)
      group.add_board(food)
      group.update!(root_board_id: home.id)

      expect(group.reload.seed_display_images!).to be(true)

      expect(home.reload.display_image_url).to eq("https://cdn.example.com/food.png")
      expect(food.reload.display_image_url).to eq("https://cdn.example.com/apple.png")
      # Pinned by reference, never by copying the board's URL into the column.
      expect(group.reload.cover_board_id).to eq(home.id)
      expect(group.read_attribute(:display_image_url)).to be_blank
      expect(group.display_image_url).to eq("https://cdn.example.com/food.png")
    end

    it "does not overwrite a cover that is already pinned" do
      home = create(:board, user: user, name: "Home")
      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "food", src: "https://cdn.example.com/food.png")
      add_tile(food, label: "apple", src: "https://cdn.example.com/apple.png")

      group = BoardGroup.create!(user: user, name: "Set", settings: { "cover_board_id" => food.id })
      group.add_board(home)
      group.add_board(food)

      expect(group.reload.seed_display_images!).to be(false)
      expect(group.reload.cover_board_id).to eq(food.id)
      # Member boards are still seeded even when the cover is left alone.
      expect(home.reload.display_image_url).to eq("https://cdn.example.com/food.png")
    end

    it "does not overwrite an explicitly chosen display_image_url column" do
      home = create(:board, user: user, name: "Home")
      add_tile(home, label: "food", src: "https://cdn.example.com/food.png")

      group = BoardGroup.create!(user: user, name: "Set", display_image_url: "https://cdn.example.com/cover.png")
      group.add_board(home)

      expect(group.reload.seed_display_images!).to be(false)
      expect(group.reload.display_image_url).to eq("https://cdn.example.com/cover.png")
    end

    it "is a no-op when no member board can resolve an image" do
      home = create(:board, user: user, name: "Home")
      add_tile(home, label: "food")

      group = BoardGroup.create!(user: user, name: "Set")
      group.add_board(home)

      expect(group.reload.seed_display_images!).to be(false)
      expect(group.reload.cover_board_id).to be_blank
    end
  end

  describe "Boards::BoardGroupCreator" do
    it "seeds display images for the new group and its member boards" do
      home = create(:board, user: user, name: "Home")
      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "Food", src: "https://cdn.example.com/food.png", links_to: food)
      add_tile(food, label: "apple", src: "https://cdn.example.com/apple.png")

      group = Boards::BoardGroupCreator.new(board: home, user: user).call

      expect(group.cover_board_id).to eq(home.id)
      # Root falls back to its own first tile; the linked page takes the folder
      # tile that opens it.
      expect(group.display_image_url).to eq("https://cdn.example.com/food.png")
      expect(food.reload.display_image_url).to eq("https://cdn.example.com/food.png")
    end
  end
end
