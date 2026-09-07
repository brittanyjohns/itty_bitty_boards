# frozen_string_literal: true

require "rails_helper"

# Issue #871 — a board that joins the public catalogue must earn a cover
# without anyone editing it afterwards.
RSpec.describe Board, "public-catalogue preview hook", type: :model do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before { allow(GenerateBoardPreviewJob).to receive(:perform_async) }

  def board_with_tiles(**attrs)
    board = create(:board, user: admin, parent_id: admin.id, **attrs)
    create(:board_image, board: board, image: create(:image))
    board.reload
  end

  it "renders a cover when an existing board is published into the catalogue" do
    board = board_with_tiles(predefined: true, published: false)

    board.update!(published: true)

    expect(GenerateBoardPreviewJob).to have_received(:perform_async).with(board.id, hash_including("generate_png" => true))
  end

  it "renders a cover when a published board is flagged predefined" do
    board = board_with_tiles(predefined: false, published: true)

    board.update!(predefined: true)

    expect(GenerateBoardPreviewJob).to have_received(:perform_async).with(board.id, anything)
  end

  it "does not re-render for an ordinary save of a catalogue board" do
    board = board_with_tiles(predefined: true, published: true)
    RSpec::Mocks.space.proxy_for(GenerateBoardPreviewJob).reset
    allow(GenerateBoardPreviewJob).to receive(:perform_async)

    board.update!(description: "a new description")

    expect(GenerateBoardPreviewJob).not_to have_received(:perform_async)
  end

  it "leaves a board that already has a cover alone" do
    board = board_with_tiles(predefined: true, published: false, display_image_url: "https://cdn.example.com/cover.png")

    board.update!(published: true)

    expect(GenerateBoardPreviewJob).not_to have_received(:perform_async)
  end

  it "does not fire for a user publishing their own board" do
    board = create(:board, user: create(:user), published: false, predefined: false)
    create(:board_image, board: board, image: create(:image))

    board.reload.update!(published: true)

    expect(GenerateBoardPreviewJob).not_to have_received(:perform_async)
  end

  # Every catalogue seeder saves the board published and adds tiles afterwards,
  # so this is the NORMAL path into the sweep, not an error.
  it "defers to the sweep, with a log line, when the board has no tiles yet" do
    allow(Rails.logger).to receive(:info)
    board = create(:board, user: admin, parent_id: admin.id, predefined: true, published: false)

    board.update!(published: true)

    expect(GenerateBoardPreviewJob).not_to have_received(:perform_async)
    expect(Rails.logger).to have_received(:info)
      .with(/board #{board.id} entered the public catalogue with no tiles/)
  end

  describe ".missing_public_preview" do
    it "selects only catalogue boards with tiles and no cover" do
      wanted = board_with_tiles(predefined: true, published: true)
      board_with_tiles(predefined: true, published: false)
      board_with_tiles(predefined: false, published: true)
      create(:board, user: admin, parent_id: admin.id, predefined: true, published: true)

      expect(Board.missing_public_preview.pluck(:id)).to eq([wanted.id])
    end
  end
end
