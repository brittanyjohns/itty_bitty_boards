require "rails_helper"

RSpec.describe Etsy::PushListingVideo do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }

  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 6)
  end
  let(:listing) do
    printable.etsy_listings.create!(
      etsy_listing_id: 987, etsy_listing_url: "https://etsy.test/987",
      state: "published", published_at: 1.day.ago,
    )
  end

  let(:client) { instance_double(Etsy::Client) }

  before do
    printable.attach_video!(bytes: "mp4-bytes", duration: 9.0)
    allow(client).to receive(:upload_video).and_return(true)
  end

  def push = described_class.new(listing.tap { printable.reload }, client: client).call

  describe "a successful push" do
    it "uploads the clip to the attached listing and stamps that it went" do
      expect(client).to receive(:upload_video).with(987, hash_including(bytes: "mp4-bytes"))

      expect(push.ok?).to be true
      expect(listing.reload.video_pushed_at).to be_present
    end

    it "clears a previous error" do
      listing.update_columns(error: "an earlier failure")

      push

      expect(listing.reload.error).to be_nil
    end

    # Etsy's rule is per LISTING, so a printable's standalone listing and its
    # bundle can both take the same rendered clip. The old printable-wide stamp
    # would have refused the second — this is a bug the row fixes.
    it "lets a sibling listing take the same clip" do
      listing.mark_video_pushed!
      sibling = printable.etsy_listings.create!(
        etsy_listing_id: 988, state: "published", published_at: 1.day.ago, purpose: "bundle",
      )

      expect(client).to receive(:upload_video).with(988, hash_including(bytes: "mp4-bytes"))

      expect(described_class.new(sibling, client: client).call.ok?).to be true
    end
  end

  describe "the one-video-per-listing guard" do
    it "refuses a second push and names the seller UI as the way to replace it" do
      listing.mark_video_pushed!

      result = push

      expect(result.ok?).to be false
      expect(result.error).to match(/already been sent to listing 987/)
      expect(result.error).to match(/seller UI/)
      expect(client).not_to have_received(:upload_video)
    end

    # The publish path uploads a video as part of creating the draft. If that
    # didn't stamp the column, this service would happily post a SECOND one.
    it "is closed by the publish path too" do
      fresh = BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
      fresh.attach_video!(bytes: "mp4", duration: 9.0)
      fresh.attach_pdf!(filename: "b.pdf", bytes: "pdf", variant: BoardPrintable::VARIANT_FULL)
      fresh.update!(listing_copy: { "title" => "T", "description" => "D", "tags" => [], "price_cents" => 500 })

      publish_client = instance_double(Etsy::Client)
      allow(publish_client).to receive(:assert_known_taxonomy!).and_return(true)
      allow(publish_client).to receive(:create_listing).and_return({ listing_id: 55, url: "https://etsy.test/55" })
      allow(publish_client).to receive(:set_listing_price).and_return(true)
      allow(publish_client).to receive(:upload_image).and_return(true)
      allow(publish_client).to receive(:upload_file).and_return(true)
      allow(publish_client).to receive(:upload_video).and_return(true)
      allow_any_instance_of(Boards::Printables::RenderListingImages).to receive(:call) do
        BoardPrintable::LISTING_IMAGE_ORDER.each { |v| fresh.attach_image!(bytes: "png", variant: v) }
      end

      fresh_listing = fresh.etsy_listings.create!(state: "publishing")
      Etsy::PublishBoardPrintableListing.new(fresh_listing, client: publish_client).call

      expect(fresh_listing.reload.video_pushed_at).to be_present
      expect(fresh_listing.can_push_video?).to be false
    end
  end

  describe "guards" do
    it "refuses a row with no attached draft" do
      listing.supersede!

      expect(push.ok?).to be false
      expect(client).not_to have_received(:upload_video)
    end

    it "refuses a printable with no video" do
      printable.video_files.each(&:purge)
      printable.reload

      result = push

      expect(result.ok?).to be false
      expect(result.error).to match(/no listing video/i)
    end
  end

  describe "a failed upload" do
    # The stamp is what makes a second push refusable, so writing it on failure
    # would lock the listing out of ever getting its video.
    it "records the error and leaves the push available to retry by hand" do
      allow(client).to receive(:upload_video).and_raise(Etsy::Client::Error, "413 too large")

      result = push

      expect(result.ok?).to be false
      expect(listing.reload.video_pushed_at).to be_nil
      expect(listing.error).to match(/413 too large/)
      expect(listing.can_push_video?).to be true
    end
  end

  describe "the drafts-only invariant" do
    it "adds media and sends no listing state" do
      push

      # Adding a video is an additive POST. The absence of an update or delete
      # call is what keeps this from being a listing mutation.
      expect(Etsy::Client.instance_methods).not_to include(:activate_listing, :update_listing, :delete_video)
    end
  end

  describe "replacing a listing" do
    # A replacement is a DIFFERENT row, whose stamp is nil by construction — so
    # nothing has to remember to clear anything, and the detached row keeps the
    # true record of what its own draft received.
    it "leaves the superseded row stamped and starts the replacement unstamped" do
      listing.mark_video_pushed!
      listing.supersede!

      replacement = printable.etsy_listings.create!(purpose: listing.purpose)

      expect(listing.reload.video_pushed_at).to be_present
      expect(replacement.video_pushed_at).to be_nil
    end
  end
end
