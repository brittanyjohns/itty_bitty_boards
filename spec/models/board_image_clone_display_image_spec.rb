require "rails_helper"

# "" in display_image_url is the "this tile has no picture" marker
# (BoardImage#picture_hidden?) — an authored choice about the TILE. Both clone
# paths dup a BoardImage and then re-point image_id at an Image resolved for the
# new owner, and set_defaults used to overwrite the dup'd value unconditionally,
# silently un-hiding every hidden tile on every clone.
RSpec.describe "Cloning a board preserves the hidden-picture marker" do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:owner) { create(:user) }
  let(:image) { create(:image, user: owner, label: "apple") }
  let(:board) { create(:board, user: owner, name: "Snacks") }

  before do
    image.update_columns(src_url: "https://cdn.example.com/apple.webp")
    board.add_image(image.id)
    board.board_images.reset
  end

  def tile
    board.board_images.find_by(image_id: image.id)
  end

  describe "BoardImage#set_defaults" do
    it "leaves a hidden tile hidden" do
      tile.update_column(:display_image_url, "")

      copy = tile.dup
      copy.board_id = create(:board, user: owner).id
      copy.save!

      expect(copy.reload.display_image_url).to eq("")
    end

    it "still seeds an empty tile from the resolved image" do
      tile.update_column(:display_image_url, nil)

      copy = tile.dup
      copy.board_id = create(:board, user: owner).id
      copy.save!

      expect(copy.reload.display_image_url).to eq("https://cdn.example.com/apple.webp")
    end
  end

  describe "Board#clone_with_images" do
    it "keeps a hidden tile hidden on the clone" do
      tile.update_column(:display_image_url, "")

      cloned = board.clone_with_images(owner.id, "Snacks copy")

      expect(cloned.board_images.first.display_image_url).to eq("")
    end

    it "gives a normal tile a picture on the clone" do
      cloned = board.clone_with_images(owner.id, "Snacks copy 2")

      expect(cloned.board_images.first.display_image_url).to be_present
    end
  end
end
