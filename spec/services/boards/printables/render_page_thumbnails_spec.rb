require "rails_helper"

RSpec.describe Boards::Printables::RenderPageThumbnails do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }

  let(:grover_opts) { [] }

  before do
    grover = instance_double(Grover, to_jpeg: "jpeg-bytes")
    allow(Grover).to receive(:new) do |_html, **opts|
      grover_opts << opts
      grover
    end
  end

  it "returns one inline thumbnail per board, keyed by board id" do
    result = described_class.new(boards: [board, other]).call

    expect(result.keys).to contain_exactly(board.id, other.id)
    expect(result[board.id].data_uri).to start_with("data:image/jpeg;base64,")
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
end
