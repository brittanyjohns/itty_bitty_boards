require "rails_helper"

RSpec.describe Boards::Printables::RenderListingImages do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
  end

  # Grover shells out to headless Chrome; the specs care about what gets
  # rendered and attached, not about the pixels.
  let(:rendered_html) { [] }

  before do
    grover = instance_double(Grover, to_png: "png-bytes")
    allow(Grover).to receive(:new) do |html, **_opts|
      rendered_html << html
      grover
    end
  end

  it "attaches a cover and a what's-included image, tagged as images not PDFs" do
    described_class.new(printable: printable).call

    printable.reload
    expect(printable.listing_images_view.map { |i| i[:variant] })
      .to eq([BoardPrintable::IMAGE_COVER, BoardPrintable::IMAGE_WHATS_INCLUDED])
    # The download buttons and the API read files_view; marketing images must
    # never leak into it.
    expect(printable.files_view).to be_empty
  end

  it "renders through the print layout with the square-canvas flag set" do
    described_class.new(printable: printable).call

    expect(rendered_html.length).to eq(2)
    expect(rendered_html).to all(include("as-listing-image"))
  end

  it "writes a fresh key on every render so a regenerate isn't hidden by the CDN" do
    described_class.new(printable: printable).call
    first = printable.reload.image_files.map(&:key)

    described_class.new(printable: printable.reload).call
    second = printable.reload.image_files.map(&:key)

    expect(second & first).to be_empty
    expect(printable.image_files.size).to eq(2)
  end

  it "names the boards in a set on the what's-included slide" do
    printable.update!(board_ids: [board.id, other.id], include_subboards: true)

    described_class.new(printable: printable).call

    expect(rendered_html.last).to include("Core Words", "Feelings")
  end

  it "caps the named boards so a large tree can't overflow the slide" do
    ids = [board.id]
    (described_class::MAX_LABELS + 3).times do |i|
      ids << create(:board, user: owner, name: "Page #{i}").id
    end
    printable.update!(board_ids: ids, include_subboards: true)

    described_class.new(printable: printable).call

    expect(rendered_html.last).to include("and 4 more")
  end
end
