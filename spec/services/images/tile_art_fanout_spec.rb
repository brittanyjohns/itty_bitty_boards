require "rails_helper"

RSpec.describe Images::TileArtFanout do
  # Images are SHARED library rows. This spec is the regression harness for the
  # rule that a tile's picture belongs to the board's owner.
  let(:owner) { FactoryBot.create(:user) }
  let(:stranger) { FactoryBot.create(:user) }
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  let(:image) { FactoryBot.create(:image, user: owner, label: "apple") }
  let(:owner_board) { FactoryBot.create(:board, user: owner) }
  let(:stranger_board) { FactoryBot.create(:board, user: stranger) }
  let(:admin_board) { FactoryBot.create(:board, user: admin) }

  let(:old_url) { "https://cdn.example.com/old.webp" }
  let(:new_url) { "https://cdn.example.com/fresh.webp" }

  def tile_on(board)
    image.board_images.find_by(board_id: board.id)
  end

  def add_tile(board, display_image_url:)
    board.add_image(image.id)
    image.board_images.reset
    tile_on(board).tap { |bi| bi.update_column(:display_image_url, display_image_url) }
  end

  describe "ownership scope" do
    it "repoints an empty tile on the actor's own board" do
      add_tile(owner_board, display_image_url: nil)

      described_class.call(image, url: new_url, actor: owner)

      expect(tile_on(owner_board).reload.display_image_url).to eq(new_url)
    end

    it "never touches a stranger's board" do
      add_tile(stranger_board, display_image_url: nil)

      described_class.call(image, url: new_url, actor: owner)

      expect(tile_on(stranger_board).reload.display_image_url).to be_nil
    end

    it "still fills admin-owned tiles so the shared library stays populated" do
      add_tile(admin_board, display_image_url: nil)

      described_class.call(image, url: new_url, actor: owner)

      expect(tile_on(admin_board).reload.display_image_url).to eq(new_url)
    end

    it "reaches admin boards only when there is no actor" do
      add_tile(admin_board, display_image_url: nil)
      add_tile(stranger_board, display_image_url: nil)

      described_class.call(image, url: new_url, actor: nil)

      expect(tile_on(admin_board).reload.display_image_url).to eq(new_url)
      expect(tile_on(stranger_board).reload.display_image_url).to be_nil
    end

    it "accepts a bare user id as the actor" do
      add_tile(owner_board, display_image_url: nil)

      described_class.call(image, url: new_url, actor: owner.id)

      expect(tile_on(owner_board).reload.display_image_url).to eq(new_url)
    end
  end

  describe "pinned tiles" do
    it "leaves a tile pinned to some other picture alone" do
      add_tile(owner_board, display_image_url: "https://cdn.example.com/my_pick.webp")

      described_class.call(image, url: new_url, actor: owner, replacing: old_url)

      expect(tile_on(owner_board).reload.display_image_url)
        .to eq("https://cdn.example.com/my_pick.webp")
    end

    it "moves a tile that was still tracking the old default" do
      add_tile(owner_board, display_image_url: old_url)

      described_class.call(image, url: new_url, actor: owner, replacing: old_url)

      expect(tile_on(owner_board).reload.display_image_url).to eq(new_url)
    end

    it "overwrites the actor's own pin when force is given" do
      add_tile(owner_board, display_image_url: "https://cdn.example.com/my_pick.webp")

      described_class.call(image, url: new_url, actor: owner, force: true)

      expect(tile_on(owner_board).reload.display_image_url).to eq(new_url)
    end

    it "still refuses a stranger's board even with force" do
      add_tile(stranger_board, display_image_url: "https://cdn.example.com/their_pick.webp")

      described_class.call(image, url: new_url, actor: owner, force: true)

      expect(tile_on(stranger_board).reload.display_image_url)
        .to eq("https://cdn.example.com/their_pick.webp")
    end
  end

  describe "the \"\" hidden-picture marker" do
    # "" is truthy in Ruby and both .blank? and .present? mis-handle it, which
    # is exactly how the old code un-hid deliberately blanked tiles.
    it "is never overwritten, even on the actor's own board with force" do
      add_tile(owner_board, display_image_url: "")

      described_class.call(image, url: new_url, actor: owner, force: true)

      expect(tile_on(owner_board).reload.display_image_url).to eq("")
    end

    it "is never overwritten by a replacing sweep" do
      add_tile(owner_board, display_image_url: "")

      described_class.call(image, url: new_url, actor: owner, replacing: old_url)

      expect(tile_on(owner_board).reload.display_image_url).to eq("")
    end

    it "is never overwritten by a dead-URL repair" do
      add_tile(owner_board, display_image_url: "")

      described_class.call(image, url: new_url, actor: nil, repair_dead: true)

      expect(tile_on(owner_board).reload.display_image_url).to eq("")
    end
  end

  describe "repair_dead" do
    it "repairs a dead URL even on a stranger's board" do
      add_tile(stranger_board, display_image_url: old_url)
      allow(image).to receive(:authorized_to_view_url?).with(old_url).and_return(false)

      described_class.call(image, url: new_url, actor: nil, repair_dead: true)

      expect(tile_on(stranger_board).reload.display_image_url).to eq(new_url)
    end

    # The ownership test comes first, so a sweep that names an actor pays for
    # no HEAD request it could not act on. A popular label ("more", "help") has
    # hundreds of placements, almost all of them out of scope.
    it "does not probe a stranger's tile when an actor is named" do
      add_tile(stranger_board, display_image_url: old_url)
      expect(image).not_to receive(:authorized_to_view_url?)

      described_class.call(image, url: new_url, actor: owner, repair_dead: true)

      expect(tile_on(stranger_board).reload.display_image_url).to eq(old_url)
    end

    it "repairs a dead URL on the actor's own board" do
      add_tile(owner_board, display_image_url: old_url)
      allow(image).to receive(:authorized_to_view_url?).with(old_url).and_return(false)

      described_class.call(image, url: new_url, actor: owner, repair_dead: true)

      expect(tile_on(owner_board).reload.display_image_url).to eq(new_url)
    end

    it "leaves a live URL on a stranger's board alone" do
      add_tile(stranger_board, display_image_url: old_url)
      allow(image).to receive(:authorized_to_view_url?).with(old_url).and_return(true)

      described_class.call(image, url: new_url, actor: nil, repair_dead: true)

      expect(tile_on(stranger_board).reload.display_image_url).to eq(old_url)
    end
  end

  it "does nothing when there is no URL to point at" do
    add_tile(owner_board, display_image_url: nil)

    expect(described_class.call(image, url: nil, actor: owner)).to eq([])
    expect(tile_on(owner_board).reload.display_image_url).to be_nil
  end

  # The freshly minted URL is known-good; a popular label has hundreds of
  # placements and must not cost a HEAD request each.
  it "does not validate the URL it was just handed" do
    add_tile(owner_board, display_image_url: nil)
    expect(image).not_to receive(:authorized_to_view_url?)

    described_class.call(image, url: new_url, actor: owner)
  end

  describe ".clear" do
    it "clears the actor's and admin's tiles but not a stranger's" do
      add_tile(owner_board, display_image_url: old_url)
      add_tile(admin_board, display_image_url: old_url)
      add_tile(stranger_board, display_image_url: old_url)

      described_class.clear(image, actor: owner)

      expect(tile_on(owner_board).reload.display_image_url).to be_nil
      expect(tile_on(admin_board).reload.display_image_url).to be_nil
      expect(tile_on(stranger_board).reload.display_image_url).to eq(old_url)
    end

    it "leaves a hidden tile hidden" do
      add_tile(owner_board, display_image_url: "")

      described_class.clear(image, actor: owner)

      expect(tile_on(owner_board).reload.display_image_url).to eq("")
    end
  end
end
