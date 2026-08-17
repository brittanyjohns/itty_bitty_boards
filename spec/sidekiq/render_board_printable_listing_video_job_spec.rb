require "rails_helper"

RSpec.describe RenderBoardPrintableListingVideoJob do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
  end

  let(:renderer) { instance_double(Boards::Printables::RenderListingVideo, call: nil) }

  before do
    allow(VideoTranscoder).to receive(:available?).and_return(true)
    allow(Boards::Printables::RenderListingVideo).to receive(:new).and_return(renderer)
  end

  it "renders the video for a finished printable" do
    described_class.new.perform(printable.id)

    expect(renderer).to have_received(:call)
  end

  # A half-generated printable has no pages to flip through yet.
  it "leaves a printable that is still generating alone" do
    printable.update_columns(status: "generating")

    described_class.new.perform(printable.id)

    expect(renderer).not_to have_received(:call)
  end

  it "does nothing when ffmpeg isn't installed" do
    allow(VideoTranscoder).to receive(:available?).and_return(false)

    described_class.new.perform(printable.id)

    expect(renderer).not_to have_received(:call)
  end

  it "shrugs off a printable that has since been deleted" do
    expect { described_class.new.perform(printable.id + 10_000) }.not_to raise_error
  end

  # An ffmpeg failure is rarely transient and every attempt is minutes of
  # headless Chrome, so this retries less than the images job.
  it "retries less eagerly than the gallery render" do
    expect(described_class.sidekiq_options["retry"])
      .to be < RenderBoardPrintableListingImagesJob.sidekiq_options["retry"]
  end
end
