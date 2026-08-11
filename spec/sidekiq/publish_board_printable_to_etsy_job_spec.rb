require "rails_helper"

RSpec.describe PublishBoardPrintableToEtsyJob do
  let(:board) { create(:board) }
  let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id]) }

  it "never retries — a retry after a partial success creates a duplicate listing in a live shop" do
    expect(described_class.sidekiq_options["retry"]).to eq(0)
  end

  it "publishes the printable" do
    service = instance_double(Etsy::PublishBoardPrintable, call: true)
    expect(Etsy::PublishBoardPrintable).to receive(:new).with(printable).and_return(service)

    described_class.new.perform(printable.id)
  end

  it "does nothing when the printable already has a listing" do
    printable.update!(etsy_listing_id: 99)

    expect(Etsy::PublishBoardPrintable).not_to receive(:new)
    described_class.new.perform(printable.id)
  end

  it "does nothing when the printable has been deleted" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
