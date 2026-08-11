require "rails_helper"

RSpec.describe Boards::Printables::RenderPageThumbnails do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }

  let(:grover_opts) { [] }

  before do
    grover = instance_double(Grover, to_png: "png-bytes")
    allow(Grover).to receive(:new) do |_html, **opts|
      grover_opts << opts
      grover
    end
    # The trim decodes a real PNG; "png-bytes" isn't one. It already fails soft,
    # but stubbing keeps that off the critical path of these examples — the trim
    # has its own coverage below.
    allow_any_instance_of(described_class).to receive(:trim_trailing_blank) { |_, png| [png, 600, 700] }
  end

  it "returns one inline thumbnail per board, keyed by board id" do
    result = described_class.new(boards: [board, other]).call

    expect(result.keys).to contain_exactly(board.id, other.id)
    expect(result[board.id].data_uri).to start_with("data:image/png;base64,")
  end

  # The slides size the page card from an explicit aspect ratio built out of
  # these. Without them the card falls back to a percentage height that can't
  # resolve, and the bottom of every board page gets sliced off.
  describe "the dimensions the slides size their cards from" do
    it "reports the thumbnail's real size after the trim" do
      result = described_class.new(boards: [board]).call

      expect(result[board.id]).to have_attributes(width: 600, height: 700)
    end

    it "falls back to the viewport when the image can't be measured" do
      allow_any_instance_of(described_class)
        .to receive(:trim_trailing_blank) { |_, png| [png, nil, nil] }
      allow_any_instance_of(Boards::RenderAssetData)
        .to receive(:call).and_return({landscape: false, tiles: [], columns: 1, rows: 1})

      result = described_class.new(boards: [board]).call

      expect(result[board.id]).to have_attributes(
        width: described_class::PORTRAIT[:width] * described_class::SCALE,
        height: described_class::PORTRAIT[:height] * described_class::SCALE,
      )
    end
  end

  # Grover reads device_scale_factor only from inside viewport; the same trap
  # that shipped 816px listing images. Pinned here too because a soft thumbnail
  # is just as invisible in a passing spec.
  it "asks for the retina scale where Grover actually reads it" do
    described_class.new(boards: [board]).call

    expect(grover_opts.first[:viewport]).to include(
      device_scale_factor: described_class::SCALE,
    )
  end

  it "matches the page viewport to the board's own orientation" do
    allow_any_instance_of(Boards::RenderAssetData)
      .to receive(:call).and_return({landscape: true, tiles: [], columns: 1, rows: 1})

    described_class.new(boards: [board]).call

    expect(grover_opts.first[:viewport]).to include(
      width: described_class::LANDSCAPE[:width],
      height: described_class::LANDSCAPE[:height],
    )
  end

  # A marketing image is not the product. One board failing to screenshot costs
  # its tile; it must not take down the gallery render or the printable.
  it "drops a board whose render blows up and keeps the rest" do
    allow(Boards::RenderAssetData).to receive(:new).and_call_original
    allow(Boards::RenderAssetData).to receive(:new)
      .with(hash_including(board: board))
      .and_raise(StandardError, "boom")

    result = described_class.new(boards: [board, other]).call

    expect(result.keys).to eq([other.id])
  end

  # Which page variant gets screenshotted is the caller's decision — the gallery
  # needs colour-with-header for the hero and both inks without a header for the
  # two what's-included grids.
  it "renders the colour page with its header by default" do
    expect(Boards::RenderAssetData).to receive(:new)
      .with(hash_including(hide_colors: false, hide_header: false)).and_call_original

    described_class.new(boards: [board]).call
  end

  it "renders the low-ink page the buyer also receives when asked for it" do
    expect(Boards::RenderAssetData).to receive(:new)
      .with(hash_including(hide_colors: true, hide_header: true)).and_call_original

    described_class.new(boards: [board], hide_colors: true, hide_header: true).call
  end

  # How much of a Letter sheet a board fills depends on its shape — a wide,
  # short grid leaves over half the page blank, and on a listing slide that
  # reads as a broken image rather than as a margin.
  describe "trimming the blank paper below the board" do
    subject(:service) { described_class.new(boards: []) }

    # The outer stub short-circuits the method under test here.
    before { allow_any_instance_of(described_class).to receive(:trim_trailing_blank).and_call_original }

    def png_with_content_height(content_height, total_height: 400, width: 200)
      image = ChunkyPNG::Image.new(width, total_height, ChunkyPNG::Color::WHITE)
      content_height.times { |y| width.times { |x| image[x, y] = ChunkyPNG::Color.rgb(20, 70, 110) } }
      image.to_blob
    end

    it "cuts the blank rows off the bottom, keeping a margin, and reports the new size" do
      png = png_with_content_height(100)

      bytes, width, height = service.send(:trim_trailing_blank, png)
      trimmed = ChunkyPNG::Image.from_blob(bytes)

      expect(trimmed.height).to eq(100 + described_class::TRIM_MARGIN_PX)
      expect(trimmed.width).to eq(200)
      expect([width, height]).to eq([trimmed.width, trimmed.height])
    end

    it "leaves a page whose content runs to the bottom edge alone" do
      png = png_with_content_height(400, total_height: 400)

      bytes, width, height = service.send(:trim_trailing_blank, png)

      expect(ChunkyPNG::Image.from_blob(bytes).height).to eq(400)
      expect([width, height]).to eq([200, 400])
    end

    # An untrimmed thumbnail is a worse-looking slide, not a broken one.
    it "returns the original bytes and no measurement when the image can't be decoded" do
      expect(service.send(:trim_trailing_blank, "not-a-png")).to eq(["not-a-png", nil, nil])
    end
  end
end
