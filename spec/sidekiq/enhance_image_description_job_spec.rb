require "rails_helper"

RSpec.describe EnhanceImageDescriptionJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:menu) { FactoryBot.create(:menu, user: user) }
  let(:board) do
    FactoryBot.create(:board, user: user, board_type: "menu",
                              parent_type: "Menu", parent_id: menu.id)
  end

  before do
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
  end

  it "refunds the whole spend when vision extraction produces nothing" do
    txn = CreditService.spend!(user, feature_key: "menu_create", amount: 15)
    board.update!(settings: (board.settings || {}).merge(
      "menu_credit" => { "txn_id" => txn.id, "per_image" => 1, "reserved" => 10 },
    ))
    allow_any_instance_of(Menu).to receive(:enhance_image_description).and_return(nil)

    expect {
      described_class.new.perform(menu.id, board.id)
    }.to change { user.reload.plan_credits_balance }.by(15)

    expect(board.reload.status).to eq("error")
  end
end
