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
      .to receive(:trim_trailing_blank) { |_, png| [png, 600, 700] }
    allow(Boards::RenderAssetData).to receive(:new).and_call_original
  end

  # Slides only — the thumbnail renders go through the same Grover stub.
  def slide_html = rendered_html.select { |html| html.include?("slide-stack") }

  def slide_count = BoardPrintable::LISTING_IMAGE_ORDER.size

  it "attaches the gallery slides in rank order, tagged as images not PDFs" do
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

    expect(slide_html.length).to eq(slide_count)
    expect(slide_html).to all(include("class=\"slide"))
    expect(slide_html.join("\n")).not_to include("as-listing-image")
  end

  # "Also includes a low-ink version" in a bullet is a claim; the same boards
  # shown printed pale is proof. It has to be the REAL low-ink page, not the
  # colour one relabelled.
  it "shows the low-ink pages on their own slide, rendered with the colour off" do
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new).and_call_original

    described_class.new(printable: printable).call

    expect(Boards::Printables::RenderPageThumbnails).to have_received(:new)
      .with(hash_including(hide_colors: true, hide_header: true))

    colour, low_ink = slide_html[2], slide_html[3]
    expect(colour).to include("What&#39;s included")
    expect(low_ink).to include("Low-ink version included")
  end

  # The page header is where the printed QR lives, and the hero's whole claim is
  # that the sheet itself carries the code. The grid tiles are a sixth the size
  # and the header there is just the slide's own title band again.
  it "keeps the page header on the hero and drops it from the grids" do
    described_class.new(printable: printable).call

    expect(Boards::RenderAssetData).to have_received(:new)
      .with(hash_including(hide_colors: false, hide_header: false)).at_least(:once)
    expect(Boards::RenderAssetData).to have_received(:new)
      .with(hash_including(hide_colors: false, hide_header: true)).at_least(:once)
  end

  # Without this the page card falls back to a percentage height that can't
  # resolve against an indefinite parent, and every board page is clipped.
  it "sizes every page card from the thumbnail's real dimensions" do
    described_class.new(printable: printable).call

    expect(slide_html.first).to include("aspect-ratio: 600 / 700")
  end

  # A shop page of listings that share one colourway reads as the same product
  # photographed five times.
  it "skins the slides in the palette the board hashes to" do
    palette = Boards::Printables::Palette.for(board)

    described_class.new(printable: printable).call

    expect(slide_html).to all(include("--accent: #{palette.accent}"))
  end

  # Grover reads device_scale_factor only from inside viewport. A top-level one
  # is accepted silently and ignored, which shipped 816px listing images for
  # months — invisible in every other spec, because the render still succeeds.
  it "asks for the retina scale where Grover actually reads it" do
    described_class.new(printable: printable).call

    # Slide renders are interleaved with thumbnail renders, so they're picked
    # out by the square canvas rather than by position.
    slide_opts = rendered_opts.select { |o| o.dig(:viewport, :width) == described_class::CANVAS_PX }
    expect(slide_opts.size).to eq(slide_count)
    expect(slide_opts).to all(
      include(viewport: {
        width: described_class::CANVAS_PX,
        height: described_class::CANVAS_PX,
        device_scale_factor: described_class::SCALE,
      }),
    )
    expect(described_class::CANVAS_PX * described_class::SCALE).to be >= 2000
  end

  # The expensive half of this job is the page thumbnails, and it is planned up
  # front so Grover is only paid for pages that get shown. Three passes and no
  # more: colour-with-header for the hero, then colour and low-ink without a
  # header for the two grids. A fourth means a slide is re-rendering pixels it
  # already had.
  it "renders each page variant once and shares it across the slides" do
    printable.update!(board_ids: [board.id, other.id], include_subboards: true)
    passes = []
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new) do |boards:, **opts|
      passes << opts.merge(boards: boards.size)
      instance_double(
        Boards::Printables::RenderPageThumbnails,
        call: boards.to_h { |b| [b.id, thumbnail_for(b)] },
      )
    end

    described_class.new(printable: printable).call

    expect(passes.size).to eq(3)
    expect(passes.map { |p| p[:hide_colors] }).to contain_exactly(nil, false, true)
    expect(slide_html.first).to include("data:image/png;base64,core-words")
  end

  # The hero is a shop window, not an inventory: past three the pages are too
  # small to tell apart, and paying Grover for them is pure waste.
  it "never renders more hero pages than the hero can show" do
    printable.update!(board_ids: Array.new(6) { create(:board, user: owner).id })
    hero_boards = nil
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new).and_wrap_original do |orig, boards:, **opts|
      hero_boards ||= boards.size if opts[:hide_header].blank?
      orig.call(boards: boards, **opts)
    end

    described_class.new(printable: printable).call

    expect(hero_boards).to eq(described_class::HERO_TILES)
  end

  it "names the boards in a set on the what's-included slide" do
    printable.update!(board_ids: [board.id, other.id], include_subboards: true)

    described_class.new(printable: printable).call

    expect(slide_html[2]).to include("Core Words", "Feelings")
  end

  # The one claim a buyer is least likely to believe from text alone.
  it "warps the root board onto a tablet" do
    described_class.new(printable: printable).call

    device = slide_html[1]
    expect(device).to include("matrix3d(", "mockup-screen")
    expect(device).to include("data:image/jpeg;base64,")
  end

  # What sits on the glass is the app, not a sheet of paper: the same board
  # inside SpeakAnyWay's own chrome, titled with the board's name. A bare
  # printed page there reads as a photograph of a printout taped to a tablet,
  # which is the opposite of what this slide is for.
  it "shows the board inside the app's chrome, titled with the board name" do
    described_class.new(printable: printable).call

    screen = rendered_html.find { |html| html.include?("app-chrome") }
    expect(screen).to be_present
    expect(screen).to include("Core Words", "sentence-bar", "Sign in")
    # The board on the screen is the header-less render, so the printed
    # scan-me band never ends up on the glass.
    expect(screen).not_to include("Created with SpeakAnyWay AAC")
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
      width: 600,
      height: 700,
    )
  end
end
