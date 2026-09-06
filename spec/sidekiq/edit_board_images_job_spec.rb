require "rails_helper"

# Bulk img2img. The credit shape mirrors GenerateImagesJob: the caller pre-paid
# per tile against one spend txn, so a tile that fails gives its own cost back.
RSpec.describe EditBoardImagesJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user) }
  let(:per_image) { CreditService.cost_for("image_edit") }

  before do
    reset_user_credits!(user)
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
  end

  def tile(src_url: "https://cdn.example.com/apple.webp")
    image = FactoryBot.create(:image, user: user, src_url: src_url)
    board.add_image(image.id)
    board.board_images.find_by(image_id: image.id)
  end

  # The spend the controller would have made, handed to the job the same way.
  def reserve!(count)
    txn = CreditService.spend!(user, feature_key: "image_edit", amount: count * per_image)
    { "credit_txn_id" => txn.id, "credit_per_image" => per_image }
  end

  describe "a successful edit" do
    it "marks the tile edited and refunds nothing" do
      bi = tile
      allow_any_instance_of(BoardImage).to receive(:create_image_edit!)
        .and_return("https://cdn.example.com/edited.webp")
      options = reserve!(1)

      expect {
        described_class.new.perform(board.id, [bi.id], "higher contrast", false, options)
      }.not_to change { user.reload.plan_credits_balance }

      expect(bi.reload.status).to eq("edited")
    end

    it "broadcasts once so an open editor repaints without a reload" do
      bi = tile
      allow_any_instance_of(BoardImage).to receive(:create_image_edit!).and_return("https://x/e.webp")

      expect_any_instance_of(Board).to receive(:broadcast_board_update!).once

      described_class.new.perform(board.id, [bi.id], "higher contrast")
    end
  end

  describe "a failed edit" do
    it "marks the tile errored and refunds exactly one image" do
      bi = tile
      allow_any_instance_of(BoardImage).to receive(:create_image_edit!).and_return(nil)
      options = reserve!(1)

      expect {
        described_class.new.perform(board.id, [bi.id], "higher contrast", false, options)
      }.to change { user.reload.plan_credits_balance }.by(per_image)

      expect(bi.reload.status).to eq("error")
    end

    it "does not double-refund across a replay" do
      bi = tile
      allow_any_instance_of(BoardImage).to receive(:create_image_edit!).and_return(nil)
      options = reserve!(1)

      described_class.new.perform(board.id, [bi.id], "higher contrast", false, options)

      expect {
        described_class.new.perform(board.id, [bi.id], "higher contrast", false, options)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "keeps going after one tile raises, and refunds only that one" do
      good = tile
      bad = tile
      allow_any_instance_of(BoardImage).to receive(:create_image_edit!) do |board_image, *|
        raise "OpenAI exploded" if board_image.id == bad.id
        "https://cdn.example.com/edited.webp"
      end
      options = reserve!(2)

      expect {
        described_class.new.perform(board.id, [good.id, bad.id], "higher contrast", false, options)
      }.to change { user.reload.plan_credits_balance }.by(per_image)

      expect(good.reload.status).to eq("edited")
      expect(bad.reload.status).to eq("error")
    end
  end

  # "Hide pictures" is a BLANK display_image_url, and editing art the tile is
  # not showing would silently un-hide it.
  describe "a tile with no picture to edit" do
    it "is skipped, errored and refunded rather than edited" do
      bi = tile
      bi.update_column(:display_image_url, "")
      bi.image.update!(src_url: nil)
      options = reserve!(1)

      expect_any_instance_of(BoardImage).not_to receive(:create_image_edit!)

      expect {
        described_class.new.perform(board.id, [bi.id], "higher contrast", false, options)
      }.to change { user.reload.plan_credits_balance }.by(per_image)

      expect(bi.reload.status).to eq("error")
    end
  end

  describe "without a reservation (an admin run)" do
    it "runs and refunds nothing rather than branching on the missing txn" do
      bi = tile
      allow_any_instance_of(BoardImage).to receive(:create_image_edit!).and_return(nil)

      expect {
        described_class.new.perform(board.id, [bi.id], "higher contrast")
      }.not_to change { user.reload.plan_credits_balance }

      expect(bi.reload.status).to eq("error")
    end
  end

  it "does nothing when the board is gone" do
    expect { described_class.new.perform(-1, [1], "x") }.not_to raise_error
  end
end
