require "rails_helper"

RSpec.describe Etsy::PublishBoardPrintable do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
  end

  let(:client) { instance_double(Etsy::Client) }

  before do
    printable.attach_pdf!(filename: "core-words.pdf", bytes: "pdf-bytes", variant: BoardPrintable::VARIANT_FULL)
    printable.update!(listing_copy: { "title" => "T", "description" => "D", "tags" => ["aac"], "price_cents" => 450 })

    allow(client).to receive(:assert_known_taxonomy!).and_return(true)
    allow(client).to receive(:create_listing)
      .and_return({ listing_id: 987, url: "https://etsy.test/987" })
    allow(client).to receive(:set_listing_price).and_return(true)
    allow(client).to receive(:upload_image).and_return(true)
    allow(client).to receive(:upload_file).and_return(true)

    # Grover renders the four slides; the bytes themselves are irrelevant here.
    allow_any_instance_of(Boards::Printables::RenderListingImages).to receive(:call) do
      BoardPrintable::LISTING_IMAGE_ORDER.each do |variant|
        printable.attach_image!(bytes: "png", variant: variant)
      end
      printable.purge_legacy_listing_images!
    end
  end

  def publish = described_class.new(printable.reload, client: client).call

  describe "the drafts-only invariant" do
    it "creates the listing as a draft and never asks the client to activate it" do
      expect(client).to receive(:create_listing).with(
        hash_including(title: "T", description: "D", price: 4.5, tags: ["aac"]),
      ).and_return({ listing_id: 987, url: "https://etsy.test/987" })

      publish

      # There is no activate/update path on the client at all — the absence is
      # the guarantee, so assert it rather than trusting the call list.
      expect(Etsy::Client.instance_methods).not_to include(:activate_listing, :update_listing)
    end
  end

  describe "a successful publish" do
    it "records the listing and clears any previous error" do
      printable.update_columns(etsy_error: "an earlier failure")

      result = publish

      expect(result.ok?).to be true
      expect(result.listing_id).to eq(987)
      expect(printable.reload).to have_attributes(
        etsy_listing_id: 987,
        etsy_listing_url: "https://etsy.test/987",
        etsy_error: nil,
      )
      expect(printable.etsy_published_at).to be_present
    end

    it "sets the price through the inventory endpoint even though create carried it" do
      expect(client).to receive(:set_listing_price).with(987, 4.5)
      publish
    end

    # Rank 1 is the search thumbnail, and the hero is the only slide that shows
    # the actual boards — so it has to lead.
    it "uploads the four slides in listing rank order, hero first" do
      ranks = []
      allow(client).to receive(:upload_image) { |_id, opts| ranks << [opts[:rank], opts[:filename]] }

      publish

      expect(ranks.map(&:first)).to eq((1..BoardPrintable::LISTING_IMAGE_ORDER.size).to_a)
      expect(ranks.first.last).to start_with("hero-")
    end

    it "uploads every PDF variant as a download file" do
      printable.attach_pdf!(filename: "core-words.low-ink.pdf", bytes: "b", variant: BoardPrintable::VARIANT_LOW_INK)

      expect(client).to receive(:upload_file).twice
      publish
    end

    it "renders the gallery images when they are missing, so the draft can go live" do
      expect(printable.listing_images?).to be false
      publish
      expect(printable.reload.listing_images_current?).to be true
    end

    # "Has images" isn't a strong enough guard: a printable generated before the
    # redesign has them, and they're the retired pair.
    it "re-renders a gallery left over from the retired two-image design" do
      printable.attach_image!(bytes: "old", variant: BoardPrintable::IMAGE_COVER)
      printable.attach_image!(bytes: "old", variant: BoardPrintable::IMAGE_WHATS_INCLUDED)

      publish

      expect(printable.reload.image_files.map { |f| f.metadata["variant"] })
        .to match_array(BoardPrintable::LISTING_IMAGE_ORDER)
    end

  end

  describe "guards" do
    it "refuses a printable that hasn't finished generating" do
      printable.update_columns(status: "generating")

      result = publish

      expect(result.ok?).to be false
      expect(result.error).to match(/isn't finished generating/)
      expect(client).not_to have_received(:create_listing)
    end

    it "refuses to create a second listing for the same printable" do
      printable.update!(etsy_listing_id: 111)

      result = publish

      expect(result.error).to match(/Already on Etsy as listing 111/)
      expect(client).not_to have_received(:create_listing)
    end

    it "refuses a PDF over Etsy's 20 MB cap rather than failing mid-upload" do
      printable.files.each(&:purge)
      printable.reload.attach_pdf!(
        filename: "huge.pdf", bytes: "x" * (Etsy::Client::FILE_CAP_BYTES + 1),
        variant: BoardPrintable::VARIANT_FULL,
      )

      result = publish

      expect(result.error).to match(/caps a download file at 20 MB/)
      expect(client).not_to have_received(:create_listing)
    end

    it "refuses when the listing copy has no title" do
      printable.update!(listing_copy: { "title" => "", "description" => "D" })

      expect(publish.error).to match(/title and description are required/)
    end
  end

  describe "failure handling" do
    it "records the error on the printable so it shows up in the admin" do
      allow(client).to receive(:create_listing).and_raise(Etsy::Client::Error, "Etsy POST 400: bad tags")

      result = publish

      expect(result.ok?).to be false
      expect(printable.reload.etsy_error).to eq("Etsy POST 400: bad tags")
      expect(printable.etsy_listing_id).to be_nil
    end

    it "leaves the printable's generation status untouched" do
      allow(client).to receive(:create_listing).and_raise("boom")

      publish

      expect(printable.reload.status).to eq("complete")
    end
  end
end
