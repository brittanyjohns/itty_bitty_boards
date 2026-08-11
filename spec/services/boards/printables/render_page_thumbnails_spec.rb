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
    allow_any_instance_of(described_class).to receive(:trim_trailing_blank) { |_, png| png }
  end

  it "returns one inline thumbnail per board, keyed by board id" do
    result = described_class.new(boards: [board, other]).call

    expect(result.keys).to contain_exactly(board.id, other.id)
    expect(result[board.id].data_uri).to start_with("data:image/png;base64,")
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

  it "renders in colour only, never the low-ink duplicate" do
    expect(Boards::RenderAssetData).to receive(:new)
      .with(hash_including(hide_colors: false)).and_call_original

    described_class.new(boards: [board]).call
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

    it "cuts the blank rows off the bottom, keeping a margin" do
      png = png_with_content_height(100)

      trimmed = ChunkyPNG::Image.from_blob(service.send(:trim_trailing_blank, png))

      expect(trimmed.height).to eq(100 + described_class::TRIM_MARGIN_PX)
      expect(trimmed.width).to eq(200)
    end

    it "leaves a page whose content runs to the bottom edge alone" do
      png = png_with_content_height(400, total_height: 400)

      trimmed = ChunkyPNG::Image.from_blob(service.send(:trim_trailing_blank, png))

      expect(trimmed.height).to eq(400)
    end

    # An untrimmed thumbnail is a worse-looking slide, not a broken one.
    it "returns the original bytes when the image can't be decoded" do
      expect(service.send(:trim_trailing_blank, "not-a-png")).to eq("not-a-png")
    end
  end
end
