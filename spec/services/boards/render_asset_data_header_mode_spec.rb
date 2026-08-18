require "rails_helper"

# The three header states and the sheet space each one leaves for the board.
RSpec.describe Boards::RenderAssetData, "header modes" do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Core Words") }

  def render(**kwargs)
    described_class.new(
      board: board,
      routes: Rails.application.routes.url_helpers,
      **kwargs,
    ).call
  end

  it "defaults to the full header" do
    expect(render[:header_mode]).to eq(described_class::HEADER_FULL)
  end

  it "maps the legacy hide_header flag onto the none mode" do
    data = render(hide_header: true)

    expect(data[:header_mode]).to eq(described_class::HEADER_NONE)
    expect(data[:hide_header]).to be(true)
  end

  it "lets an explicit mode win over hide_header" do
    data = render(hide_header: true, header_mode: described_class::HEADER_URL_ONLY)

    expect(data[:header_mode]).to eq(described_class::HEADER_URL_ONLY)
    # hide_header stays false so the template can't take the QR away — the two
    # can't be allowed to contradict each other.
    expect(data[:hide_header]).to be(false)
  end

  it "falls back to the full header rather than trusting an unknown mode" do
    expect(render(header_mode: "banner")[:header_mode]).to eq(described_class::HEADER_FULL)
  end

  # The reason the mode exists: url_only reserves a slim band instead of the
  # full one, so the board prints bigger, and none reserves nothing at all.
  #
  # Measured on a TALL board on purpose. A wide, short one is limited by the
  # page width rather than by what the header leaves behind, so it would print
  # the same size in all three modes and prove nothing.
  def stub_tall_board!
    tiles = 12.times.map do |i|
      { "x" => 0, "y" => i, "w" => 1, "h" => 1, "label" => "word #{i}" }
    end
    allow(Boards::BoardPdfLayoutNormalizer).to receive(:call).and_return(tiles)
    allow(board).to receive(:columns_for_screen_size).and_return(2)
  end

  it "grows the board as the header shrinks" do
    stub_tall_board!

    heights = [
      described_class::HEADER_FULL,
      described_class::HEADER_URL_ONLY,
      described_class::HEADER_NONE,
    ].map { |mode| render(header_mode: mode)[:board_render_height_mm] }

    expect(heights).to eq(heights.sort)
    expect(heights.uniq.length).to eq(3)
  end

  # "Trim-ready" is a size claim, so the band it does keep has to be a line of
  # type, not a reserved block. The QR band it replaced cost 20mm.
  it "leaves the url_only page within a few mm of a full-bleed print" do
    stub_tall_board!

    url_only = render(header_mode: described_class::HEADER_URL_ONLY)[:board_render_height_mm]
    none = render(header_mode: described_class::HEADER_NONE)[:board_render_height_mm]

    expect(none - url_only).to be <= 6.0
  end

  # The url_only page prints the address as text, so encoding a PNG for it
  # would cost a QR render per board page and reach nothing.
  it "names the board's URL on the url_only page but renders no code for it" do
    data = render(header_mode: described_class::HEADER_URL_ONLY)

    expect(data[:qr_target_url]).to be_present
    expect(data[:qr_data_url]).to be_nil
  end

  it "still builds a QR for the full header" do
    expect(render[:qr_data_url]).to start_with("data:image/")
  end
end
