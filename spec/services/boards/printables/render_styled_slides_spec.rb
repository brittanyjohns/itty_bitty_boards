require "rails_helper"

RSpec.describe Boards::Printables::RenderStyledSlides do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core 60") }
  let(:feelings) { create(:board, user: owner, name: "Feelings") }

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id, feelings.id], page_count: 21)
  end

  let(:rendered_html) { [] }
  let(:rendered_opts) { [] }

  before do
    grover = instance_double(Grover, to_png: "png-bytes")
    allow(Grover).to receive(:new) do |html, **opts|
      rendered_html << html
      rendered_opts << opts
      grover
    end
    allow_any_instance_of(Boards::Printables::RenderPageThumbnails)
      .to receive(:trim_trailing_blank) { |_, png| [png, 1584, 1100] }
  end

  def slide_html = rendered_html.select { |html| html.include?("styled-slide") }

  def slide_opts = rendered_opts.select { |o| o.dig(:viewport, :width) == described_class::CANVAS_W }

  it "attaches each styled slide as a shared image stamped with the spec and facts" do
    described_class.new(printable: printable).call

    printable.reload
    files = printable.styled_image_files
    expect(files.map { |f| f.metadata["variant"] }).to eq(BoardPrintable::STYLED_IMAGE_VARIANTS)
    expect(files.map { |f| f.metadata["kind"] }).to all(eq(BoardPrintable::KIND_IMAGE))
    expect(files.map { |f| f.metadata["spec_version"] }).to all(eq(BoardPrintable::STYLED_SPEC_VERSION))
    expect(files.map { |f| f.metadata["facts_digest"] }).to all(eq(Printables::GalleryFacts.new(printable).digest))
    expect(printable.styled_slides_current?).to be(true)
  end

  it "leaves the legacy gallery and the buyer downloads alone" do
    described_class.new(printable: printable).call

    printable.reload
    expect(printable.listing_images_view).to be_empty
    expect(printable.files_view).to be_empty
  end

  # Grover reads device_scale_factor only from inside viewport.
  it "renders 4:3 at the retina scale, nested where Grover reads it" do
    described_class.new(printable: printable).call

    expect(slide_opts.size).to eq(BoardPrintable::STYLED_IMAGE_VARIANTS.size)
    expect(slide_opts).to all(include(viewport: { width: 1200, height: 900, device_scale_factor: 2 }))
    expect(described_class::CANVAS_W * described_class::SCALE).to be >= 2000
  end

  it "renders through the styled layout with every font inlined" do
    described_class.new(printable: printable).call

    expect(slide_html).to all(include("font-family: 'Caveat'", "font-family: 'Fredoka'", "font-family: 'Nunito'"))
    expect(slide_html.join).not_to include("fonts.googleapis.com")
  end

  it "prints the facts the boards give, not numbers from a template" do
    allow_any_instance_of(Printables::GalleryFacts).to receive(:word_count).and_return(309)

    described_class.new(printable: printable).call

    hero = slide_html.first
    expect(hero).to include("2 communication boards", "309 symbol-supported words")
    expect(hero).to include("Core 60 Boards")
    # Only PDFs ship. Checked against the badge copy rather than the raw HTML,
    # whose base64 font data can contain "PNG" by chance.
    expect(Printables::StyledSlideCopy.hero_badges(Printables::GalleryFacts.new(printable)).join(" ")).not_to include("PNG")
  end

  it "shows the real low-ink page only when a low-ink file ships" do
    printable.attach_pdf!(filename: "color.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_COLOR)
    printable.attach_pdf!(filename: "low-ink.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_LOW_INK)
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new).and_call_original

    described_class.new(printable: printable).call

    expect(Boards::Printables::RenderPageThumbnails).to have_received(:new)
      .with(hash_including(hide_colors: true)) { |args| expect(args[:boards]).to eq([board]) }
    expect(slide_html.first).to include("Color + low-ink versions")
  end

  it "makes no low-ink claim and no low-ink render when none ships" do
    printable.attach_pdf!(filename: "color.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_COLOR)
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new).and_call_original

    described_class.new(printable: printable).call

    expect(Boards::Printables::RenderPageThumbnails).not_to have_received(:new).with(hash_including(hide_colors: true))
    expect(slide_html.join).not_to include("low-ink")
  end

  # The printed QR inside the page header must stay the bare /pb/<slug>: a
  # UTM-tagged URL is too dense to scan off paper.
  it "renders pages with the bare board QR target" do
    allow(Boards::RenderAssetData).to receive(:new).and_call_original

    described_class.new(printable: printable).call

    expect(Boards::RenderAssetData).to have_received(:new)
      .with(hash_including(qr_target_url: Boards::Printables::Qr.target_url_for(board))).at_least(:once)
    expect(Boards::RenderAssetData).not_to have_received(:new)
      .with(hash_including(qr_target_url: a_string_including("utm_")))
  end

  it "renders only the variants asked for" do
    described_class.new(printable: printable, variants: [BoardPrintable::IMAGE_STYLED_WHATS_INCLUDED]).call

    expect(slide_html.size).to eq(1)
    expect(slide_html.first).to include("What&#39;s included")
    expect(printable.reload.styled_image_files.map { |f| f.metadata["variant"] })
      .to eq([BoardPrintable::IMAGE_STYLED_WHATS_INCLUDED])
  end

  it "refuses a variant it does not render" do
    expect { described_class.new(printable: printable, variants: ["hero"]) }.to raise_error(ArgumentError)
  end
end
