require "rails_helper"

RSpec.describe Boards::Printables::RenderListingImages do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }

  # 7 is what one board really merges to — cover, how-to-use, the three board
  # pages, license, credits — so a slide quoting `page_count` is visibly wrong.
  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 7)
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

  # Slides render in LISTING_IMAGE_ORDER, so a variant's rendered HTML is at its
  # rank. Looked up by NAME rather than by a literal index: inserting a slide
  # renumbers every one after it, and a spec asserting on slide_html[2] then
  # fails somewhere unrelated to what it was testing.
  def slide_for(variant)
    slide_html[BoardPrintable::LISTING_IMAGE_ORDER.index(variant)]
  end

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

    colour = slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED)
    low_ink = slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED_LOW_INK)
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

  # The middle card of the fan is the one drawn in front and uncropped, and the
  # hero is the search-grid thumbnail. Tree order puts the root first, which is
  # the rotated card at the BACK — so what sold the listing was whichever
  # subboard came second, typically the sparsest page in the set.
  describe "the hero fan" do
    # The stubbed thumbnails are the only data URIs whose payload is a bare
    # slug, so a full match up to the closing quote can't collide with the
    # logo's or the QR's real base64.
    def hero_board_order
      slide_html.first.scan(%r{data:image/png;base64,([a-z0-9-]+)"}).flatten
    end

    it "puts the root board in the middle, in front of its subboards" do
      third = create(:board, user: owner, name: "Places")
      printable.update!(board_ids: [board.id, other.id, third.id], include_subboards: true)
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      expect(hero_board_order).to eq(%w[feelings core-words places])
    end

    it "fronts the root board when a set only has two pages" do
      printable.update!(board_ids: [board.id, other.id], include_subboards: true)
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      expect(hero_board_order).to eq(%w[feelings core-words])
    end

    it "leaves a single-board hero alone" do
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      expect(hero_board_order).to eq(%w[core-words])
    end

    # The layout used to carry an nth-child(1)/(2)/(3) ladder, so a fourth and
    # fifth card got no transform, no negative margin and no z-index and half
    # the pile ended up off the slide. The geometry is written inline now, and
    # this is the assertion that it actually closes.
    it "writes a geometry that keeps every card inside the stage" do
      printable.update!(board_ids: Array.new(5) { create(:board, user: owner).id })
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      hero = slide_html.first
      width = hero[/--fan-w:\s*([\d.]+)%/, 1].to_f
      overlap = hero[/--fan-overlap:\s*([\d.]+)%/, 1].to_f
      cards = hero.scan(/--rot:\s*(-?[\d.]+)deg/).flatten

      expect(cards.size).to eq(described_class::HERO_TILES)
      expect((cards.size * width) - ((cards.size - 1) * overlap))
        .to be <= Boards::Printables::HeroFan::MAX_COVERAGE
      # The middle card is the root board's, and it is the one drawn flat.
      expect(cards[cards.size / 2].to_f).to eq(0.0)
    end

    # RenderPageThumbnails omits any board whose render failed, and tiles_from
    # drops the tile with it. A fan sized from board_ids rather than from the
    # tiles that survived leaves a gap in the pile.
    it "sizes the fan to the pages that rendered, not to the boards asked for" do
      printable.update!(board_ids: [board.id, other.id, create(:board, user: owner).id])
      stub_thumbnail_renders!(skip: other)

      described_class.new(printable: printable).call

      expect(slide_html.first.scan(/--rot:/).size).to eq(2)
    end
  end

  describe "the flip-book slide" do
    it "earns rank 2, straight behind the search thumbnail" do
      expect(BoardPrintable::LISTING_IMAGE_ORDER[1]).to eq(BoardPrintable::IMAGE_FLIP_BOOK)
    end

    it "shows the root opening its subpages, each with a way back" do
      third = create(:board, user: owner, name: "Places")
      printable.update!(board_ids: [board.id, other.id, third.id], include_subboards: true)
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      slide = slide_for(BoardPrintable::IMAGE_FLIP_BOOK)
      expect(slide).to include("flip-card is-root")
      # Matched on markup: the layout inlines its CSS, so the bare class name is
      # in every slide's <style> block.
      expect(slide.scan('<div class="flip-back">').size).to eq(described_class::FLIP_BOOK_CHILDREN)
      expect(slide).to include("data:image/png;base64,core-words")
    end

    # The slide can't be skipped for a single board — LISTING_IMAGE_ORDER
    # defines a current gallery, so a conditional variant would leave every
    # small printable permanently stale. Only the copy changes.
    it "still renders for a single board, with copy that fits one page" do
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      slide = slide_for(BoardPrintable::IMAGE_FLIP_BOOK)
      expect(slide).to include(Printables::SlideCopy.flip_book_headline(board_count: 1))
      expect(slide).not_to include('<div class="flip-back">')
    end

    it "adds no page renders of its own" do
      printable.update!(board_ids: [board.id, other.id])
      passes = []
      allow(Boards::Printables::RenderPageThumbnails).to receive(:new) do |boards:, **opts|
        passes << opts
        instance_double(
          Boards::Printables::RenderPageThumbnails,
          call: boards.to_h { |b| [b.id, thumbnail_for(b)] },
        )
      end

      described_class.new(printable: printable).call

      expect(passes.size).to eq(3)
    end
  end

  describe "the page index" do
    it "names every board in the set, in tree order, root first" do
      third = create(:board, user: owner, name: "Places")
      printable.update!(board_ids: [board.id, other.id, third.id], include_subboards: true)
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      slide = slide_for(BoardPrintable::IMAGE_PAGE_INDEX)
      expect(slide.index("Core Words")).to be < slide.index("Feelings")
      expect(slide.index("Feelings")).to be < slide.index("Places")
      expect(slide).to include("is-root")
    end

    # whats_included caps its thumbnails at 8 and says "+17 more"; this is the
    # slide where a big set is meant to be fully legible, so what it drops it
    # has to count.
    it "counts what it had to leave off rather than dropping it silently" do
      printable.update!(board_ids: Array.new(30) { create(:board, user: owner).id })
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      slide = slide_for(BoardPrintable::IMAGE_PAGE_INDEX)
      expect(slide.scan('<span class="index-label">').size).to eq(described_class::PAGE_INDEX_ROWS)
      expect(slide).to include("+ #{30 - described_class::PAGE_INDEX_ROWS} more pages")
    end

    it "asks a single board what's on it rather than counting pages" do
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      expect(slide_for(BoardPrintable::IMAGE_PAGE_INDEX)).to include("What&#39;s on this board")
    end
  end

  # Etsy caps a listing at ten photos. The video is a separate slot and doesn't
  # count against it.
  it "leaves room in Etsy's gallery for something hand-made" do
    expect(BoardPrintable::LISTING_IMAGE_ORDER.size).to be < 10
  end

  describe "the bundle sticker" do
    it "counts the whole set, even when the hero could only show some of it" do
      printable.update!(board_ids: Array.new(9) { create(:board, user: owner).id })
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      # Matched on the markup, not the bare class name — the layout inlines all
      # of its CSS, so ".count-sticker" is in every slide's <style> block.
      expect(slide_html.first).to include('<div class="count-sticker">', ">9<", "LINKED")
      expect(slide_html.first).to include("COLOUR · LOW-INK · TRIM-READY")
    end

    # "1 LINKED BOARD" undersells a single-page printable and reads as a bug.
    it "is absent from a single-board hero" do
      stub_thumbnail_renders!

      described_class.new(printable: printable).call

      expect(slide_html.first).not_to include('<div class="count-sticker">')
    end
  end

  it "names the boards in a set on the what's-included slide" do
    printable.update!(board_ids: [board.id, other.id], include_subboards: true)

    described_class.new(printable: printable).call

    expect(slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED)).to include("Core Words", "Feelings")
  end

  # The "In your download" panel is read against the listing description, so it
  # counts what the description counts: board pages, never the cover,
  # how-to-use, license and credits pages wrapped around them.
  describe "the in-your-download panel" do
    it "quotes a single board's three board pages, not the merged seven" do
      described_class.new(printable: printable).call

      expect(slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED)).to include("3-page board PDF")
      expect(slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED)).not_to include("7-page")
    end

    it "counts every board in a set once per variant across the three files" do
      printable.update!(board_ids: [board.id, other.id], include_subboards: true, page_count: 26)

      described_class.new(printable: printable).call

      expect(slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED)).to include("2 boards, 6 pages")
      expect(slide_for(BoardPrintable::IMAGE_WHATS_INCLUDED)).not_to include("26 pages")
    end
  end

  # The one claim a buyer is least likely to believe from text alone.
  it "warps the root board onto a tablet" do
    described_class.new(printable: printable).call

    device = slide_for(BoardPrintable::IMAGE_ON_A_DEVICE)
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

  # Etsy does not letterbox a square photo. The listing page frames it 4:5 and
  # cover-crops, taking 10% off each side; at the old flat 56px inset that
  # sliced the first letter off the board name and better than half the QR on
  # every listing in the shop. The margin is the whole fix, so it is asserted
  # rather than left to a comment.
  describe "the horizontal safe zone" do
    # Every rule that positions CONTENT against a side edge. Band fills still
    # bleed; it is the type, the QR and the logo that have to move in.
    SAFE_ZONE_RULES = [
      ".slide-stack",       # title banner, headline, audio badge, page stage
      ".instant-ribbon",
      ".footer-strip",
      ".footer-strip .site-mark",
      ".logo-corner",
    ].freeze

    let(:css) { slide_html.first }

    def declarations_for(selector)
      css[/^\s*#{Regexp.escape(selector)}\s*\{(.*?)\}/m, 1]
    end

    it "reserves more than the 10% of each side that Etsy's 4:5 crop takes" do
      described_class.new(printable: printable).call

      safe_x = css[/--safe-x:\s*(\d+)px/, 1]&.to_i
      expect(safe_x).to be_present
      expect(safe_x).to be >= described_class::CANVAS_PX * 0.10
    end

    it "insets every content-bearing edge from the token, never a literal" do
      described_class.new(printable: printable).call

      SAFE_ZONE_RULES.each do |selector|
        block = declarations_for(selector)
        expect(block).to be_present, "#{selector} is gone — move its inset, don't drop it"
        expect(block).to include("var(--safe-x)"),
                         "#{selector} sets a side inset Etsy will crop through:\n#{block}"
      end
    end

    # The rules above all inset from the token because they sit on the slide.
    # The count sticker sits inside .slide-stack, which has already paid the
    # inset — so its own safety is simply that it never reaches back OUT of that
    # container. It carries the biggest numeral on the slide, and a negative
    # side offset here puts that numeral straight under Etsy's 4:5 crop.
    it "keeps the count sticker inside the container that pays the inset" do
      described_class.new(printable: printable).call

      block = declarations_for(".count-sticker")
      expect(block).to be_present
      expect(block).not_to match(/(?:left|right):\s*-/),
                           "the count sticker reaches outside the safe zone:\n#{block}"
    end
  end

  # Real thumbnails all decode to the same stubbed bytes, so the board a card is
  # showing is only distinguishable when each render is keyed to its board.
  # `skip` stands in for a board whose page render failed: the real class omits
  # it from the hash rather than returning a nil thumbnail.
  def stub_thumbnail_renders!(skip: nil)
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new) do |boards:, **_opts|
      rendered = boards.reject { |b| b.id == skip&.id }
      instance_double(
        Boards::Printables::RenderPageThumbnails,
        call: rendered.to_h { |b| [b.id, thumbnail_for(b)] },
      )
    end
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
