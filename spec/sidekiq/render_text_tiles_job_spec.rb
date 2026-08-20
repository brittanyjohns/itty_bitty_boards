require "rails_helper"

RSpec.describe RenderTextTilesJob do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }
  let(:first_tile) { create(:board_image, board: board, image: create(:image, user: user, label: "more")) }
  let(:second_tile) { create(:board_image, board: board, image: create(:image, user: user, label: "want")) }

  def entry(tile, **params)
    [tile.id, Images::TextTile::Options.from_params({ text: tile.label }.merge(params)).to_h]
  end

  it "runs on the text queue, not behind the OpenAI work" do
    expect(described_class.sidekiq_options["queue"].to_s).to eq("text_images")
  end

  it "renders every tile in the selection" do
    rendered = []
    allow(Images::TextTile::Creator).to receive(:call) do |board_image:, options:, **|
      rendered << [board_image.id, options.text]
    end

    described_class.new.perform([entry(first_tile), entry(second_tile)])

    expect(rendered).to contain_exactly([first_tile.id, "more"], [second_tile.id, "want"])
  end

  it "hands the creator the board's owner and suppresses the per-tile broadcast" do
    expect(Images::TextTile::Creator).to receive(:call).once do |user:, broadcast:, **|
      expect(user).to eq(self.user)
      expect(broadcast).to be(false)
    end

    described_class.new.perform([entry(first_tile)])
  end

  # One broadcast per board, not one per tile — the whole point of batching.
  it "broadcasts each board once at the end" do
    allow(Images::TextTile::Creator).to receive(:call)
    expect_any_instance_of(Board).to receive(:broadcast_board_update!).once

    described_class.new.perform([entry(first_tile), entry(second_tile)])
  end

  it "fails only the tile that blew up, and still renders the rest" do
    allow(Images::TextTile::Creator).to receive(:call) do |board_image:, **|
      raise "chrome died" if board_image.id == first_tile.id
    end

    expect { described_class.new.perform([entry(first_tile), entry(second_tile)]) }
      .to raise_error(/#{first_tile.id}/)

    expect(first_tile.reload.status).to eq("failed")
    expect(second_tile.reload.status).not_to eq("failed")
  end

  it "is a no-op for a tile deleted between enqueue and run" do
    allow(Images::TextTile::Creator).to receive(:call)

    expect { described_class.new.perform([[-1, { "text" => "gone" }]]) }.not_to raise_error
  end

  it "tolerates an empty selection" do
    expect { described_class.new.perform([]) }.not_to raise_error
  end
end
