# frozen_string_literal: true

require "rails_helper"

# Issue #871 — 9 of 67 boards on /api/public_boards had never had a cover
# rendered, because nothing enqueued one when a board joined the catalogue.
RSpec.describe PublicBoardPreviewSweepJob, type: :job do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def catalogue_board(**attrs)
    board = create(:board, user: admin, parent_id: admin.id, predefined: true, published: true, **attrs)
    create(:board_image, board: board, image: create(:image))
    board.reload
  end

  before { allow(GenerateBoardPreviewJob).to receive(:perform_async) }

  it "enqueues a render for a catalogue board with tiles and no cover" do
    board = catalogue_board

    expect(described_class.new.perform).to eq(1)
    expect(GenerateBoardPreviewJob).to have_received(:perform_async).with(board.id, hash_including("generate_png" => true))
    expect(board.reload.preview_status).to eq("queued")
  end

  it "skips a board that already has a chosen cover" do
    catalogue_board(display_image_url: "https://cdn.example.com/cover.png")

    expect(described_class.new.perform).to eq(0)
    expect(GenerateBoardPreviewJob).not_to have_received(:perform_async)
  end

  it "skips a catalogue board with no tiles — there is nothing to photograph" do
    create(:board, user: admin, parent_id: admin.id, predefined: true, published: true)

    expect(described_class.new.perform).to eq(0)
  end

  it "skips a board that is published but not in the catalogue" do
    board = create(:board, user: create(:user), published: true, predefined: false)
    create(:board_image, board: board, image: create(:image))

    expect(described_class.new.perform).to eq(0)
  end

  it "caps a run and leaves the rest for the next sweep" do
    3.times { catalogue_board }
    allow(described_class).to receive(:max_per_run).and_return(2)

    expect(described_class.new.perform).to eq(2)
    expect(GenerateBoardPreviewJob).to have_received(:perform_async).twice
  end

  it "logs the boards it enqueued" do
    board = catalogue_board
    allow(Rails.logger).to receive(:info)

    described_class.new.perform

    expect(Rails.logger).to have_received(:info).with(/enqueued 1 of 1 public board.*#{board.id}/)
  end

  it "keeps sweeping when one board's enqueue raises, and names it" do
    first, second = [catalogue_board, catalogue_board].sort_by(&:id)
    allow_any_instance_of(Board).to receive(:run_generate_preview_job).and_wrap_original do |m, *args|
      raise Redis::CannotConnectError, "boom" if m.receiver.id == first.id
      m.call(*args)
    end
    allow(Rails.logger).to receive(:error)

    expect(described_class.new.perform).to eq(1)
    expect(Rails.logger).to have_received(:error).with(/enqueue failed for board #{first.id}/)
    expect(second.reload.preview_status).to eq("queued")
  end
end
