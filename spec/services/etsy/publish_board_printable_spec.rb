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

    # Grover renders the gallery slides; the bytes themselves are irrelevant here.
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

    # Rank 1 is the search thumbnail, and it is the photoreal in-use mockup —
    # the listings the shop audit rated "Strong" all led with a photograph of
    # the product in a real room, not with flat board art.
    it "uploads every slide in listing rank order, the paper mockup first" do
      ranks = []
      allow(client).to receive(:upload_image) { |_id, opts| ranks << [opts[:rank], opts[:filename]] }

      publish

      expect(ranks.map(&:first)).to eq((1..BoardPrintable::LISTING_IMAGE_ORDER.size).to_a)
      expect(ranks.first.last).to start_with("#{BoardPrintable::LISTING_IMAGE_ORDER.first.dasherize}-")
    end

    it "uploads every PDF variant as a download file" do
      printable.attach_pdf!(filename: "core-words.low-ink.pdf", bytes: "b", variant: BoardPrintable::VARIANT_LOW_INK)
      printable.attach_pdf!(filename: "core-words.trim-ready.pdf", bytes: "c", variant: BoardPrintable::VARIANT_TRIM_READY)

      expect(client).to receive(:upload_file).exactly(3).times
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

    # A board printable ships three files, comfortably inside Etsy's five. The
    # guard is here for the fourth variant nobody remembers to count — Etsy
    # rejects the extra upload after the draft already exists.
    it "refuses more download files than a listing can carry" do
      (Etsy::Client::MAX_DOWNLOAD_FILES + 1).times do |i|
        printable.attach_pdf!(filename: "extra-#{i}.pdf", bytes: "x", variant: BoardPrintable::VARIANT_COLOR)
      end

      result = publish

      expect(result.error).to match(/caps a listing at 5 download files/)
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

  describe "the listing video" do
    before { allow(client).to receive(:upload_video).and_return(true) }

    def attach_video!
      printable.attach_video!(bytes: "mp4-bytes", duration: 9.4)
      printable.reload
    end

    it "uploads the attached clip alongside the draft" do
      attach_video!

      expect(client).to receive(:upload_video).with(987, hash_including(bytes: "mp4-bytes"))

      expect(publish.ok?).to be true
    end

    # A printable is published exactly once, so a draft never already has a
    # video and Etsy's one-per-listing rule can't be hit.
    it "is skipped entirely when nothing has been rendered" do
      expect(client).not_to receive(:upload_video)

      expect(publish.ok?).to be true
    end

    # A draft carrying images and download files is finishable without a video.
    # Failing the publish would leave a real listing already created in the
    # shop while reporting failure, which is a manual cleanup rather than a
    # retry.
    it "does not fail the publish when the upload is rejected" do
      attach_video!
      allow(client).to receive(:upload_video).and_raise(Etsy::Client::Error, "Etsy POST 413: too big")

      result = publish

      expect(result.ok?).to be true
      expect(result.listing_id).to eq(987)
      expect(printable.reload.etsy_listing_id).to eq(987)
      expect(printable.etsy_error).to include("listing video failed to upload")
    end

    # The gallery is auto-rendered at publish because Etsy won't let a listing
    # with no photos go live. Video has no such rule, and rendering one here
    # would put ffmpeg inside a job that is deliberately never retried.
    it "is never rendered on the fly the way the gallery is" do
      expect_any_instance_of(Boards::Printables::RenderListingVideo).not_to receive(:call)

      publish

      expect(printable.reload.listing_video?).to be false
    end
  end
end
