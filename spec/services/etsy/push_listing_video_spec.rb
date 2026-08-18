require "rails_helper"

RSpec.describe Etsy::PushListingVideo do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }

  let(:printable) do
    BoardPrintable.create!(
      board: board, status: "complete", board_ids: [board.id], page_count: 6,
      etsy_listing_id: 987, etsy_listing_url: "https://etsy.test/987", etsy_published_at: 1.day.ago,
    )
  end

  let(:client) { instance_double(Etsy::Client) }

  before do
    printable.attach_video!(bytes: "mp4-bytes", duration: 9.0)
    allow(client).to receive(:upload_video).and_return(true)
  end

  def push = described_class.new(printable.reload, client: client).call

  describe "a successful push" do
    it "uploads the clip to the attached listing and stamps that it went" do
      expect(client).to receive(:upload_video).with(987, hash_including(bytes: "mp4-bytes"))

      expect(push.ok?).to be true
      expect(printable.reload.etsy_video_pushed_at).to be_present
    end

    it "clears a previous error" do
      printable.update_columns(etsy_error: "an earlier failure")

      push

      expect(printable.reload.etsy_error).to be_nil
    end
  end

  describe "the one-video-per-listing guard" do
    it "refuses a second push and names the seller UI as the way to replace it" do
      printable.update_columns(etsy_video_pushed_at: 1.hour.ago)

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

      Etsy::PublishBoardPrintable.new(fresh, client: publish_client).call

      expect(fresh.reload.etsy_video_pushed?).to be true
      expect(fresh.can_push_listing_video?).to be false
    end
  end

  describe "guards" do
    it "refuses a printable with no attached listing" do
      printable.update_columns(etsy_listing_id: nil)

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
      expect(printable.reload.etsy_video_pushed_at).to be_nil
      expect(printable.etsy_error).to match(/413 too large/)
      expect(printable.can_push_listing_video?).to be true
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

  describe "relisting" do
    # A detached printable is heading for a NEW draft, which has no video until
    # publishing gives it one. Leaving the stamp set would hide the control for
    # a listing that genuinely has nothing on it.
    it "clears the stamp so the replacement listing can receive one" do
      printable.update_columns(etsy_video_pushed_at: 1.hour.ago)

      printable.relist!

      expect(printable.reload.etsy_video_pushed_at).to be_nil
    end
  end
end
