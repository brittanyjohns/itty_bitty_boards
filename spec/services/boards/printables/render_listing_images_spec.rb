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
  let(:rendered_opts) { [] }

  before do
    grover = instance_double(Grover, to_png: "png-bytes", to_jpeg: "jpeg-bytes")
    allow(Grover).to receive(:new) do |html, **opts|
      rendered_html << html
      rendered_opts << opts
      grover
    end
    # The thumbnail trim decodes a real PNG; "png-bytes" isn't one. The trim
    # already fails soft, but stubbing it keeps the failure out of the logs and
    # off the critical path of these examples.
    allow_any_instance_of(Boards::Printables::RenderPageThumbnails)
      .to receive(:trim_trailing_blank) { |_, png| png }
  end

  # Slides only — the thumbnail renders go through the same Grover stub.
  def slide_html = rendered_html.select { |html| html.include?("slide-stack") }

  it "attaches the four gallery slides in rank order, tagged as images not PDFs" do
    described_class.new(printable: printable).call

    printable.reload
    expect(printable.listing_images_view.map { |i| i[:variant] })
      .to eq(BoardPrintable::LISTING_IMAGE_ORDER)
    # The download buttons and the API read files_view; marketing images must
    # never leak into it.
    expect(printable.files_view).to be_empty
  end

  it "renders each slide through the listing layout, not the print sheet" do
    described_class.new(printable: printable).call

    expect(slide_html.length).to eq(4)
    expect(slide_html).to all(include("class=\"slide"))
    expect(slide_html.join("\n")).not_to include("as-listing-image")
  end

  # Grover reads device_scale_factor only from inside viewport. A top-level one
  # is accepted silently and ignored, which shipped 816px listing images for
  # months — invisible in every other spec, because the render still succeeds.
  it "asks for the retina scale where Grover actually reads it" do
    described_class.new(printable: printable).call

    slide_opts = rendered_opts.last(4)
    expect(slide_opts).to all(
      include(viewport: {
        width: described_class::CANVAS_PX,
        height: described_class::CANVAS_PX,
        device_scale_factor: described_class::SCALE,
      }),
    )
    expect(described_class::CANVAS_PX * described_class::SCALE).to be >= 2000
  end

  # The expensive half of this job is the page thumbnails. Rendering them once
  # and sharing them is the whole reason the tile plan is built up front.
  it "renders each board page once and reuses it across the slides" do
    printable.update!(board_ids: [board.id, other.id], include_subboards: true)
    thumbs = { board.id => thumbnail_for(board), other.id => thumbnail_for(other) }
    expect(Boards::Printables::RenderPageThumbnails).to receive(:new).once.and_return(
      instance_double(Boards::Printables::RenderPageThumbnails, call: thumbs),
    )

    described_class.new(printable: printable).call

    hero, whats_included = slide_html.first(2)
    expect(hero).to include("data:image/png;base64,core-words")
    expect(whats_included).to include("data:image/png;base64,core-words")
  end

  it "names the boards in a set on the what's-included slide" do
    printable.update!(board_ids: [board.id, other.id], include_subboards: true)

    described_class.new(printable: printable).call

    expect(slide_html.second).to include("Core Words", "Feelings")
  end

  it "writes a fresh key on every render so a regenerate isn't hidden by the CDN" do
    described_class.new(printable: printable).call
    first = printable.reload.image_files.map(&:key)

    described_class.new(printable: printable.reload).call
    second = printable.reload.image_files.map(&:key)

    expect(second & first).to be_empty
    expect(printable.image_files.size).to eq(BoardPrintable::LISTING_IMAGE_ORDER.size)
  end

  # A printable from before the redesign carries cover/what's-included blobs.
  # They must not survive a re-render, or a stale image ships to a live listing.
  it "purges gallery images left over from the retired two-image design" do
    printable.attach_image!(bytes: "old", variant: BoardPrintable::IMAGE_COVER)

    described_class.new(printable: printable.reload).call

    variants = printable.reload.image_files.map { |f| f.metadata["variant"] }
    expect(variants).to match_array(BoardPrintable::LISTING_IMAGE_ORDER)
  end

  # The chrome must be self-contained: a remote <img> that 404s inside Grover
  # renders an empty box and the PNG still comes out looking almost right, so
  # the failure reaches Etsy silently. Board symbol art inside a THUMBNAIL is
  # the one documented exception, which is why this asserts on slides only.
  it "never reaches out to the network for slide chrome" do
    described_class.new(printable: printable).call

    expect(slide_html.join("\n")).not_to include('src="http')
  end

  def thumbnail_for(target)
    Boards::Printables::RenderPageThumbnails::Thumbnail.new(
      board_id: target.id,
      data_uri: "data:image/png;base64,#{target.name.parameterize}",
      landscape: true,
    )
  end
end
