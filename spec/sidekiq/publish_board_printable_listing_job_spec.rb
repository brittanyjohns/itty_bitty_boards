require "rails_helper"

RSpec.describe PublishBoardPrintableListingJob do
  let(:board) { create(:board) }
  let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id]) }
  let(:listing) { printable.etsy_listings.create!(state: "publishing", claimed_at: Time.current) }

  it "never retries — a retry after a partial success creates a duplicate listing in a live shop" do
    expect(described_class.sidekiq_options["retry"]).to eq(0)
  end

  it "publishes the claimed listing" do
    service = instance_double(Etsy::PublishBoardPrintableListing, call: true)
    expect(Etsy::PublishBoardPrintableListing).to receive(:new).with(listing).and_return(service)

    described_class.new.perform(listing.id)
  end

  # The controller's compare-and-set gates the ENQUEUE; this gates the WORK. A
  # hand-run Sidekiq retry lands after the service moved the row off
  # `publishing`, and has to stop.
  it "does nothing when the row is no longer being published" do
    listing.update!(state: "published", etsy_listing_id: 99, published_at: Time.current)

    expect(Etsy::PublishBoardPrintableListing).not_to receive(:new)
    described_class.new.perform(listing.id)
  end

  it "does nothing for a row that was never claimed" do
    pending_row = printable.etsy_listings.create!

    expect(Etsy::PublishBoardPrintableListing).not_to receive(:new)
    described_class.new.perform(pending_row.id)
  end

  it "does nothing when the row has been deleted" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
