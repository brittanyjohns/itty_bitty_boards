require "rails_helper"

RSpec.describe RenderTextTileJob do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }
  let(:board_image) { create(:board_image, board: board, image: create(:image, user: user, label: "more")) }
  let(:payload) { Images::TextTile::Options.from_params(text: "more", font: "lexend").to_h }

  it "runs on its own queue, not behind the OpenAI work" do
    expect(described_class.sidekiq_options["queue"].to_s).to eq("text_images")
  end

  it "hands the rehydrated options to the creator" do
    expect(Images::TextTile::Creator).to receive(:call) do |board_image:, user:, options:|
      expect(options.text).to eq("more")
      expect(options.font).to eq("lexend")
      expect(user).to eq(self.user)
    end

    described_class.new.perform(board_image.id, payload)
  end

  it "marks the tile failed and re-raises so Sidekiq can retry" do
    allow(Images::TextTile::Creator).to receive(:call).and_raise("chrome died")

    expect { described_class.new.perform(board_image.id, payload) }.to raise_error("chrome died")
    expect(board_image.reload.status).to eq("failed")
  end

  it "is a no-op for a tile deleted between enqueue and run" do
    expect { described_class.new.perform(-1, payload) }.not_to raise_error
  end
end
