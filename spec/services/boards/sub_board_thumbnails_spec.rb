require "rails_helper"

# A set's sub-boards take their thumbnail from the folder tile that opens them,
# rather than each being rendered to its own PNG. Rendering per page would put
# one headless-Chrome run per sub-board onto the shared :default queue — a real
# vocabulary set runs to 50-200 pages.
RSpec.describe Boards::SubBoardThumbnails, type: :service do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, name: "Root") }
  let(:child) { create(:board, user: user, name: "Food") }

  # The folder tile on `root` that opens `child`.
  def link_tile!(from: root, to: child, src_url: "https://cdn.example/food.png")
    image = create(:image, label: "food")
    image.update_column(:src_url, src_url)
    tile = create(:board_image, board: from, image: image)
    tile.update_columns(predictive_board_id: to.id)
    tile
  end

  it "gives a sub-board the image of the tile that opens it" do
    tile = link_tile!

    described_class.apply!(owner: user, board_ids: [root.id, child.id], root_id: root.id)

    expect(child.reload.read_attribute(:display_image_url)).to eq(tile.tile_image_url(user))
  end

  # The tile that opens a page often lives on a sibling rather than the root.
  it "finds the tile anywhere in the set, not just on the root" do
    sibling = create(:board, user: user, name: "Mealtime")
    tile = link_tile!(from: sibling, to: child)

    described_class.apply!(
      owner: user, board_ids: [root.id, sibling.id, child.id], root_id: root.id,
    )

    expect(child.reload.read_attribute(:display_image_url)).to eq(tile.tile_image_url(user))
  end

  it "leaves the root alone — it gets a real rendered preview" do
    link_tile!

    expect {
      described_class.apply!(owner: user, board_ids: [root.id, child.id], root_id: root.id)
    }.not_to change { root.reload.read_attribute(:display_image_url) }
  end

  it "queues no render work at all" do
    link_tile!

    expect {
      described_class.apply!(owner: user, board_ids: [root.id, child.id], root_id: root.id)
    }.not_to change { GenerateBoardPreviewJob.jobs.size }
  end

  it "skips a sub-board nothing links to" do
    orphan = create(:board, user: user, name: "Orphan")

    described_class.apply!(owner: user, board_ids: [root.id, orphan.id], root_id: root.id)

    expect(orphan.reload.read_attribute(:display_image_url)).to be_blank
  end

  it "does nothing when the set is a single board" do
    expect(described_class.apply!(owner: user, board_ids: [root.id], root_id: root.id)).to eq(0)
  end

  describe "purge_previews" do
    # Builder sub-boards are deliberately never rendered, so a stray PNG has to
    # go or it would win over the column in Board#display_image_url.
    it "drops an existing preview when asked" do
      link_tile!
      child.preview_image.attach(
        io: StringIO.new("png"), filename: "old.png", content_type: "image/png",
      )

      described_class.apply!(
        owner: user, board_ids: [root.id, child.id], root_id: root.id, purge_previews: true,
      )

      expect(child.reload.preview_image).not_to be_attached
    end

    # An IMPORTED page is an ordinary board: if the user edits it later and
    # earns a real preview, that preview should win over the folder tile.
    it "keeps an existing preview by default" do
      link_tile!
      child.preview_image.attach(
        io: StringIO.new("png"), filename: "kept.png", content_type: "image/png",
      )

      described_class.apply!(owner: user, board_ids: [root.id, child.id], root_id: root.id)

      expect(child.reload.preview_image).to be_attached
    end
  end
end
