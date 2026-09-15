require "rails_helper"

RSpec.describe Printables::GalleryFacts do
  let(:owner) { create(:user) }
  let(:core) { create(:board, user: owner, name: "Core 60") }
  let(:food) { create(:board, user: owner, name: "Food") }
  let(:printable) do
    BoardPrintable.create!(board: core, status: "complete", board_ids: [core.id, food.id])
  end

  # update_columns, not attributes on create: BoardImage#set_defaults seeds
  # display_image_url from the Image on create, and these examples need to say
  # exactly which of nil / "" / a url the tile holds.
  def tile(board, label, picture: "https://cdn.example.test/#{label}.png", **columns)
    create(:board_image, board: board, image: create(:image, label: label)).tap do |bi|
      bi.update_columns({ label: label, display_label: label, display_image_url: picture }.merge(columns))
    end
  end

  def facts = described_class.new(printable)

  describe "#word_count" do
    it "counts each word once across the set, however many pages repeat it" do
      tile(core, "this")
      tile(food, "This")
      tile(core, "want")
      tile(food, "apple")

      expect(facts.word_count).to eq(3)
    end

    it "leaves out hidden tiles, folder tiles, way-back tiles and keyboard keys" do
      tile(core, "want")
      tile(core, "secret", hidden: true)
      tile(core, "Food", data: { "mute_name" => true })
      tile(food, "Home", data: { "back_tile" => true })
      tile(core, "a", data: { "tile_type" => "letter" })

      expect(facts.word_count).to eq(1)
    end

    # "" is the "this tile has no picture" marker; it must stop the chain rather
    # than fall through to the Image's library art.
    it "does not count a tile whose picture was deliberately blanked" do
      red = tile(core, "red", picture: "")
      red.image.update_columns(src_url: "https://cdn.example.test/apple.png")

      expect(facts.word_count).to eq(0)
    end

    it "counts a tile with no picture of its own when its Image has art" do
      apple = tile(core, "apple", picture: nil)
      apple.image.update_columns(src_url: "https://cdn.example.test/apple.png")

      expect(facts.word_count).to eq(1)
    end

    it "only counts the boards the printable covers" do
      tile(core, "want")
      tile(create(:board, user: owner), "elsewhere")

      expect(facts.word_count).to eq(1)
    end
  end

  describe "file facts" do
    it "claims low-ink only when a low-ink file ships" do
      printable.attach_pdf!(filename: "color.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_COLOR)
      expect(facts.low_ink?).to be(false)

      printable.attach_pdf!(filename: "low-ink.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_LOW_INK)
      expect(described_class.new(printable.reload).low_ink?).to be(true)
    end

    it "treats the single-board document as carrying the low-ink pages" do
      printable.attach_pdf!(filename: "core.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_FULL)

      expect(facts.low_ink?).to be(true)
      expect(facts.formats_label).to eq("PDF")
    end

    it "narrows to what a listing sells" do
      printable.attach_pdf!(filename: "color.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_COLOR)
      printable.attach_pdf!(filename: "low-ink.pdf", bytes: "%PDF", variant: BoardPrintable::VARIANT_LOW_INK)
      listing = printable.etsy_listings.create!(pdf_variants: [BoardPrintable::VARIANT_COLOR])

      scoped = described_class.new(printable.reload, listing: listing)
      expect(scoped.low_ink?).to be(false)
      expect(scoped.pdf_count).to eq(1)
    end

    it "counts the PDFs and never says PNG" do
      BoardPrintable::DOWNLOAD_VARIANTS.each do |variant|
        printable.attach_pdf!(filename: "#{variant}.pdf", bytes: "%PDF", variant: variant)
      end

      expect(facts.formats_label).to eq("3 PDFs")
    end
  end

  it "counts boards from the printable, never fewer than one" do
    expect(facts.board_count).to eq(2)
    expect(facts.set?).to be(true)
  end

  describe "online facts" do
    it "points at the root's bare /pb/<slug>, and shows it without the scheme" do
      core.update_columns(slug: "core-60")

      expect(facts.online_url).to eq("https://app.speakanyway.com/pb/core-60")
      expect(facts.online_display_url).to eq("app.speakanyway.com/pb/core-60")
    end

    it "is public only when every board in the set is published" do
      core.update_columns(published: true)
      food.update_columns(published: false)
      expect(facts.online_public?).to be(false)

      food.update_columns(published: true)
      expect(facts.online_public?).to be(true)
    end

    it "goes stale when a board is published" do
      core.update_columns(published: true)
      food.update_columns(published: false)
      before = facts.digest

      food.update_columns(published: true)

      expect(facts.digest).not_to eq(before)
    end
  end

  it "changes its digest when a fact changes" do
    tile(core, "want")
    before = facts.digest

    tile(food, "apple")

    expect(facts.digest).not_to eq(before)
  end
end
