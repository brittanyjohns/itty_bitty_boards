require "rails_helper"

RSpec.describe Printables::EnsureGalleryRendered do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core 60") }
  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 7)
  end
  let(:listing) { printable.etsy_listings.create! }

  let(:rendered_opts) { [] }

  # Stubbed the way render_styled_slides_spec.rb stubs it: the styled renderer
  # runs for real, only the browser is fake.
  before do
    grover = instance_double(Grover, to_png: "png-bytes")
    allow(Grover).to receive(:new) do |_html, **opts|
      rendered_opts << opts
      grover
    end
    allow_any_instance_of(Boards::Printables::RenderPageThumbnails)
      .to receive(:trim_trailing_blank) { |_, png| [png, 1584, 1100] }

    allow(Boards::Printables::RenderStyledSlides).to receive(:new).and_call_original
    allow(Boards::Printables::RenderListingImages).to receive(:new) do |printable:, listing: nil|
      instance_double(Boards::Printables::RenderListingImages).tap do |renderer|
        allow(renderer).to receive(:call) do
          BoardPrintable::LISTING_IMAGE_ORDER.each do |variant|
            printable.attach_image!(bytes: "png", variant: variant, listing: listing)
          end
        end
      end
    end
  end

  def call = described_class.new(listing.reload).call

  def styled_slide_renders = rendered_opts.count { |o| o.dig(:viewport, :width) == 1200 }

  it "does nothing for a listing that was never curated" do
    result = call

    expect(result.styled_variants).to be_empty
    expect(result.legacy_rendered).to be false
    expect(Boards::Printables::RenderStyledSlides).not_to have_received(:new)
    expect(Boards::Printables::RenderListingImages).not_to have_received(:new)
  end

  it "renders only the styled variants the gallery names, and no legacy set when those resolve" do
    BoardPrintable::LISTING_IMAGE_ORDER.each { |v| printable.attach_image!(bytes: "png", variant: v) }
    listing.update!(gallery_items: %w[styled:styled_whats_included legacy:on_paper])

    result = call

    expect(result.styled_variants).to eq([BoardPrintable::IMAGE_STYLED_WHATS_INCLUDED])
    expect(Boards::Printables::RenderStyledSlides).to have_received(:new)
      .with(printable: printable, variants: [BoardPrintable::IMAGE_STYLED_WHATS_INCLUDED])
    expect(styled_slide_renders).to eq(1)
    expect(Boards::Printables::RenderListingImages).not_to have_received(:new)
    expect(listing.reload.listing_images_current?).to be true
  end

  it "re-renders a styled slide whose facts moved" do
    printable.attach_image!(
      bytes: "old", variant: BoardPrintable::IMAGE_STYLED_HERO,
      metadata: { spec_version: BoardPrintable::STYLED_SPEC_VERSION, facts_digest: "stale" },
    )
    listing.update!(gallery_items: %w[styled:styled_hero])

    expect(call.styled_variants).to eq([BoardPrintable::IMAGE_STYLED_HERO])
    expect(listing.reload.listing_images_current?).to be true
  end

  it "renders the legacy set when a legacy ref is missing" do
    listing.update!(gallery_items: %w[legacy:about])

    expect(call.legacy_rendered).to be true
    expect(Boards::Printables::RenderListingImages).to have_received(:new).with(printable: printable, listing: nil)
    expect(listing.reload.listing_images_current?).to be true
  end

  # The same rule the uncurated publish path follows: a topic override changes
  # what the slides say, so the listing needs its own.
  it "renders the legacy set for the listing itself when it carries a topic override" do
    BoardPrintable::LISTING_IMAGE_ORDER.each { |v| printable.attach_image!(bytes: "png", variant: v) }
    listing.update!(gallery_items: %w[legacy:about], topic_override: "school morning")

    call

    expect(Boards::Printables::RenderListingImages).to have_received(:new).with(printable: printable, listing: listing)
    expect(listing.reload.listing_images_current?).to be true
  end

  it "renders nothing when the curated gallery is already current" do
    printable.attach_image!(bytes: "png", variant: "about")
    printable.attach_image!(
      bytes: "png", variant: BoardPrintable::IMAGE_STYLED_HERO,
      metadata: { spec_version: BoardPrintable::STYLED_SPEC_VERSION, facts_digest: printable.styled_facts_digest },
    )
    listing.update!(gallery_items: %w[styled:styled_hero legacy:about])

    result = call

    expect(result.styled_variants).to be_empty
    expect(result.legacy_rendered).to be false
    expect(Grover).not_to have_received(:new)
  end
end
