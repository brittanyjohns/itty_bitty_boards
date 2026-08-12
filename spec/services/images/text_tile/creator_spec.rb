require "rails_helper"

RSpec.describe Images::TextTile::Creator do
  let(:user) { create(:user) }
  let(:image) { create(:image, user: user, label: "more") }
  let(:board) { create(:board, user: user) }
  let(:board_image) { create(:board_image, board: board, image: image) }
  let(:options) { Images::TextTile::Options.from_params(text: "more", font: "atkinson") }

  # A 1x1 PNG — enough for Active Storage to attach and for vips to variant.
  let(:png) do
    Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    )
  end

  before { allow_any_instance_of(Images::TextTile::Renderer).to receive(:to_png).and_return(png) }

  it "attaches a doc to the tile's Image, stamped as ours" do
    doc = described_class.call(board_image: board_image, user: user, options: options)

    expect(doc.documentable).to eq(image)
    expect(doc.source_type).to eq(Doc::SOURCE_TYPE_TEXT_TILE)
    expect(doc.image).to be_attached
    expect(doc.raw).to eq("more")
  end

  it "marks the tile complete and points it at the new doc" do
    doc = described_class.call(board_image: board_image, user: user, options: options)
    board_image.reload

    expect(board_image.status).to eq("complete")
    expect(board_image.display_image_url).to eq(doc.tile_url)
    expect(board_image.data.dig("text_image", "doc_id")).to eq(doc.id)
  end

  it "persists the config so the editor can restore it" do
    described_class.call(board_image: board_image, user: user, options: options)

    expect(board_image.reload.data["text_image"]).to include(options.to_h)
  end

  it "writes hide_label both ways, so unchecking the box restores the label" do
    described_class.call(board_image: board_image, user: user,
                         options: Images::TextTile::Options.from_params(text: "more", hide_label: "true"))
    expect(board_image.reload.data["hide_label"]).to be(true)

    other = create(:board_image, board: board, image: create(:image, user: user, label: "less"))
    described_class.call(board_image: other, user: user,
                         options: Images::TextTile::Options.from_params(text: "less", hide_label: "false"))
    expect(other.reload.data["hide_label"]).to be(false)
  end

  # The reason this doesn't go through ImageHelper#save_image_from_base64.
  it "does NOT repaint sibling tiles that share the same Image on another board" do
    other_board = create(:board, user: user)
    sibling = create(:board_image, board: other_board, image: image)
    # update_column: a create-time callback resolves display_image_url from the
    # Image, so the URL has to be planted after the record exists.
    sibling.update_column(:display_image_url, "https://cdn.example/original.png")

    described_class.call(board_image: board_image, user: user, options: options)

    expect(sibling.reload.display_image_url).to eq("https://cdn.example/original.png")
    expect(sibling.data["text_image"]).to be_nil
  end

  it "does not touch the shared Image's generation status" do
    image.update!(status: "pending")

    described_class.call(board_image: board_image, user: user, options: options)

    expect(image.reload.status).to eq("pending")
  end

  it "rebroadcasts the board so the open editor picks the picture up" do
    expect_any_instance_of(Board).to receive(:broadcast_board_update!)

    described_class.call(board_image: board_image, user: user, options: options)
  end
end
