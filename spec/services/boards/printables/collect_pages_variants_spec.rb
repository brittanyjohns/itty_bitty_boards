require "rails_helper"

# Which page each download variant actually renders. The walk lives in
# collect_pages_spec.rb; this covers the render side, where the trap is that
# "header-less" and "no QR" are the same flag in the print template.
RSpec.describe Boards::Printables::CollectPages, "#call" do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Core Words", slug: "core-words") }

  let(:render_args) { [] }

  before do
    allow(Grover).to receive(:new).and_return(instance_double(Grover, to_pdf: "%PDF-fake"))
    allow(ApplicationController).to receive(:render).and_return("<html></html>")

    allow(Boards::RenderAssetData).to receive(:new).and_wrap_original do |original, **kwargs|
      render_args << kwargs
      original.call(**kwargs)
    end
  end

  subject(:result) { described_class.new(board: board).call }

  it "renders one page per download variant, colour first" do
    expect(result[:pages].map(&:variant)).to eq(BoardPrintable::DOWNLOAD_VARIANTS)
  end

  it "drops the tile colours on the low-ink page only" do
    result

    by_variant = BoardPrintable::DOWNLOAD_VARIANTS.zip(render_args).to_h

    expect(by_variant[BoardPrintable::VARIANT_LOW_INK][:hide_colors]).to be(true)
    expect(by_variant[BoardPrintable::VARIANT_COLOR][:hide_colors]).to be(false)
    expect(by_variant[BoardPrintable::VARIANT_TRIM_READY][:hide_colors]).to be(false)
  end

  # The whole point of the trim-ready variant: the band goes so the board
  # prints as large as the sheet allows. It still resolves a target URL —
  # `hide_header: true` would leave the sheet with no route at all to the free
  # audio companion the listing promises; url_only prints it as one thin line.
  it "gives the trim-ready page an address line instead of the full header" do
    result

    modes = render_args.map { |kwargs| kwargs[:header_mode] }

    expect(modes).to eq([
      Boards::RenderAssetData::HEADER_FULL,
      Boards::RenderAssetData::HEADER_FULL,
      Boards::RenderAssetData::HEADER_URL_ONLY,
    ])
    expect(render_args.map { |kwargs| kwargs[:include_qr] }).to all(be(true))
  end

  it "points every variant's QR at the board's own public page" do
    result

    expect(render_args.map { |kwargs| kwargs[:qr_target_url] }.uniq)
      .to eq(["https://app.speakanyway.com/pb/core-words"])
  end
end
