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

  describe "dedupe" do
    # Rendering is the expensive part — a Grover fork spawns node + Chromium.
    # Two tiles with the same render_digest are byte-identical, so the second
    # one must never pay for it.
    def render_count
      count = 0
      allow_any_instance_of(Images::TextTile::Renderer).to receive(:to_png) do
        count += 1
        png
      end
      -> { count }
    end

    it "reuses the same Image's doc rather than rendering (or stacking) a second one" do
      counter = render_count
      first = described_class.call(board_image: board_image, user: user, options: options)

      sibling = create(:board_image, board: create(:board, user: user), image: image)
      again = described_class.call(board_image: sibling, user: user, options: options)

      expect(again).to eq(first)
      expect(counter.call).to eq(1)
      expect(image.docs.where(source_type: Doc::SOURCE_TYPE_TEXT_TILE).count).to eq(1)
      expect(sibling.reload.display_image_url).to eq(first.tile_url)
    end

    # A different Image needs its own Doc row — the row is per-Image/per-user,
    # and it shows in that tile's picture gallery — but not its own render.
    it "shares the blob with another Image's identical render" do
      counter = render_count
      first = described_class.call(board_image: board_image, user: user, options: options)

      other_image = create(:image, user: user, label: "more please")
      other_tile = create(:board_image, board: board, image: other_image)
      second = described_class.call(board_image: other_tile, user: user, options: options)

      expect(second).not_to eq(first)
      expect(second.documentable).to eq(other_image)
      expect(second.image.blob).to eq(first.image.blob)
      expect(counter.call).to eq(1)
    end

    it "renders again when anything that changes the pixels changes" do
      counter = render_count
      described_class.call(board_image: board_image, user: user, options: options)
      described_class.call(
        board_image: board_image, user: user,
        options: Images::TextTile::Options.from_params(text: "more", font: "lexend"),
      )

      expect(counter.call).to eq(2)
    end

    # hide_label is a tile setting, not paint — render_digest excludes it.
    it "does not render again for a hide_label flip" do
      counter = render_count
      described_class.call(board_image: board_image, user: user,
                           options: Images::TextTile::Options.from_params(text: "more", hide_label: "true"))
      described_class.call(board_image: board_image, user: user,
                           options: Images::TextTile::Options.from_params(text: "more", hide_label: "false"))

      expect(counter.call).to eq(1)
      expect(board_image.reload.data["hide_label"]).to be(false)
    end

    it "stamps the digest so a later render can find it" do
      doc = described_class.call(board_image: board_image, user: user, options: options)
      expect(doc.data["render_digest"]).to eq(options.render_digest)
    end

    # Another user's identical picture is fine to share bytes with, but the row
    # stays theirs — docs carry user_id and seed UserDoc.
    it "gives a second user their own doc row over the shared blob" do
      counter = render_count
      first = described_class.call(board_image: board_image, user: user, options: options)

      stranger = create(:user)
      stranger_tile = create(:board_image, board: create(:board, user: stranger), image: image)
      second = described_class.call(board_image: stranger_tile, user: stranger, options: options)

      expect(second).not_to eq(first)
      expect(second.user_id).to eq(stranger.id)
      expect(second.image.blob).to eq(first.image.blob)
      expect(counter.call).to eq(1)
    end

    it "does not reuse a doc whose bytes were purged" do
      counter = render_count
      first = described_class.call(board_image: board_image, user: user, options: options)
      first.image.purge

      described_class.call(board_image: board_image, user: user, options: options)
      expect(counter.call).to eq(2)
    end
  end

  it "can skip the broadcast, for the batch job that sends one per board" do
    expect_any_instance_of(Board).not_to receive(:broadcast_board_update!)

    described_class.call(board_image: board_image, user: user, options: options, broadcast: false)
  end
end
