require "rails_helper"

RSpec.describe GenerateImagesJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:menu) { FactoryBot.create(:menu, user: user) }
  let(:board) do
    FactoryBot.create(:board, user: user, board_type: "menu",
                              parent_type: "Menu", parent_id: menu.id)
  end
  let(:image) { FactoryBot.create(:image, user: user) }

  before do
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
    board.add_image(image.id)
  end

  def reserve!(reserved: 3)
    txn = CreditService.spend!(user, feature_key: "menu_create", amount: 5 + reserved)
    board.update!(settings: (board.settings || {}).merge(
      "menu_credit" => { "txn_id" => txn.id, "per_image" => 1, "reserved" => reserved },
    ))
  end

  describe "menu prompt selection" do
    before do
      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(nil)
    end

    it "keeps the description-driven prompt on fresh menu images" do
      prompt = "A burger topped with apple butter and bacon. Menu photo."
      menu_image = FactoryBot.create(:image, user: user, image_type: "menu",
                                             image_prompt: prompt)
      board.add_image(menu_image.id)

      described_class.new.perform([menu_image.id], board.id)

      expect(menu_image.reload.image_prompt).to eq(prompt)
    end

    it "falls back to the label-based menu prompt for reused images" do
      described_class.new.perform([image.id], board.id)

      expect(image.reload.image_prompt).to eq(image.default_menu_image_prompt(board.name))
    end
  end

  describe "non-menu prompt handling" do
    let(:plain_board) { FactoryBot.create(:board, user: user, board_type: "dynamic") }

    before do
      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(nil)
      plain_board.add_image(image.id)
    end

    # This job used to overwrite image_prompt unconditionally on every non-menu
    # board, silently discarding whatever the user had written.
    it "preserves a user's custom prompt instead of overwriting it" do
      image.update!(image_prompt: "a golden retriever wearing a party hat")

      described_class.new.perform([image.id], plain_board.id)

      expect(image.reload.image_prompt).to eq("a golden retriever wearing a party hat")
    end

    it "sends the composed house prompt while leaving the stored intent alone" do
      image.update!(image_prompt: "a golden retriever wearing a party hat")

      expect_any_instance_of(Image).to receive(:create_image_doc) do |_img, _user_id, prompt|
        expect(prompt).to include("a golden retriever wearing a party hat")
        expect(prompt).to include("Do not include any text")
        nil
      end

      described_class.new.perform([image.id], plain_board.id)
    end

    it "does not blow up when no board is given" do
      expect { described_class.new.perform([image.id], nil) }.not_to raise_error
    end
  end

  describe "menu image failure refunds" do
    before do
      allow_any_instance_of(Image).to receive(:create_image_doc).and_return(nil)
    end

    it "refunds one image credit when a menu image fails to generate" do
      reserve!

      expect {
        described_class.new.perform([image.id], board.id)
      }.to change { user.reload.plan_credits_balance }.by(1)

      expect(board.board_images.find_by(image_id: image.id).status).to eq("failed")
    end

    it "does not double-refund across the Sidekiq retry" do
      reserve!

      described_class.new.perform([image.id], board.id)
      expect {
        described_class.new.perform([image.id], board.id)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "does not refund on boards without a credit reservation" do
      expect {
        described_class.new.perform([image.id], board.id)
      }.not_to change { user.reload.plan_credits_balance }
    end
  end
end
