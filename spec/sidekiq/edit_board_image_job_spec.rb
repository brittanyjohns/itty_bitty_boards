require "rails_helper"

RSpec.describe EditBoardImageJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user) }
  let(:board_image) do
    image = FactoryBot.create(:image, user: user, src_url: "https://cdn.example.com/a.webp")
    board.add_image(image.id)
    board.board_images.find_by(image_id: image.id)
  end

  it "marks a successful edit edited" do
    allow_any_instance_of(BoardImage).to receive(:create_image_edit!).and_return("https://x/e.webp")

    described_class.new.perform(board_image.id, "higher contrast")

    expect(board_image.reload.status).to eq("edited")
  end

  # The ensure block used to run unconditionally, so a failed edit overwrote its
  # own "error" with "edited" and reported itself as finished.
  it "leaves a failed edit reporting error, not edited" do
    allow_any_instance_of(BoardImage).to receive(:create_image_edit!).and_raise("OpenAI exploded")

    expect {
      described_class.new.perform(board_image.id, "higher contrast")
    }.to raise_error("OpenAI exploded")

    expect(board_image.reload.status).to eq("error")
  end

  it "does nothing when the tile is gone" do
    expect { described_class.new.perform(-1, "x") }.not_to raise_error
  end
end
