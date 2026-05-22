require "rails_helper"

RSpec.describe "API::ChildAccounts demo (MySpeak) limits", type: :request do
  describe "POST /api/child_accounts" do
    context "as a free user creating a MySpeak ID" do
      let(:user) do
        u = create(:user, created_at: 2.months.ago)
        u.setup_free_limits
        u.save!
        u
      end

      it "creates the demo communicator capped at one board" do
        post "/api/child_accounts",
          params: { name: "My Kid", username: "my-kid-#{SecureRandom.hex(3)}", is_demo: true },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        account = ChildAccount.find_by(owner_id: user.id, is_demo: true)
        expect(account).to be_present
        expect(account.settings["demo_board_limit"]).to eq(ChildAccount::FREE_DEMO_BOARD_LIMIT)
        expect(account.settings["demo_board_limit"]).to eq(1)
      end

      it "blocks a second demo communicator once the slot is used" do
        create(:child_account, user: user, owner: user, is_demo: true)

        post "/api/child_accounts",
          params: { name: "Second", username: "second-#{SecureRandom.hex(3)}", is_demo: true },
          headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "as a pro user" do
      let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

      it "does not cap a Pro demo communicator at one board" do
        post "/api/child_accounts",
          params: { name: "Pro Kid", username: "pro-kid-#{SecureRandom.hex(3)}", is_demo: true },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        account = ChildAccount.find_by(owner_id: user.id, is_demo: true)
        expect(account.settings["demo_board_limit"]).to be_nil
      end
    end
  end
end
