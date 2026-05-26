require "rails_helper"

RSpec.describe "API::ChildAccounts sandbox + slot limits", type: :request do
  describe "POST /api/child_accounts" do
    context "as a free user creating a sandbox communicator" do
      let(:user) do
        u = create(:user, created_at: 2.months.ago)
        u.setup_free_limits
        u.save!
        u
      end

      it "creates the sandbox capped at one board" do
        post "/api/child_accounts",
          params: { name: "My Kid", username: "my-kid-#{SecureRandom.hex(3)}", status: "sandbox", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        account = ChildAccount.find_by(owner_id: user.id, status: "sandbox")
        expect(account).to be_present
        expect(account.settings["demo_board_limit"]).to eq(ChildAccount::FREE_DEMO_BOARD_LIMIT)
        expect(account.settings["demo_board_limit"]).to eq(1)
      end

      it "blocks a second sandbox once the slot is used" do
        create(:child_account, user: user, owner: user, status: "sandbox")

        post "/api/child_accounts",
          params: { name: "Second", username: "second-#{SecureRandom.hex(3)}", status: "sandbox", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "allows self-creating one non-sandbox communicator on Free" do
        post "/api/child_accounts",
          params: { name: "Real", username: "real-#{SecureRandom.hex(3)}", status: "active", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created)
      end

      it "blocks a second non-sandbox communicator once the Free slot is used" do
        create(:child_account, user: user, owner: user, status: ChildAccount::ACTIVE)

        post "/api/child_accounts",
          params: { name: "Second", username: "second-#{SecureRandom.hex(3)}", status: "active", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "still accepts the legacy is_demo=true param for backwards compat" do
        post "/api/child_accounts",
          params: { name: "Legacy", username: "legacy-#{SecureRandom.hex(3)}", is_demo: true, password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        expect(ChildAccount.where(owner_id: user.id, status: "sandbox").count).to eq(1)
      end
    end

    context "as a pro user" do
      let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

      it "does not cap a Pro sandbox at one board" do
        post "/api/child_accounts",
          params: { name: "Pro Kid", username: "pro-kid-#{SecureRandom.hex(3)}", status: "sandbox", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        account = ChildAccount.find_by(owner_id: user.id, status: "sandbox")
        expect(account.settings["demo_board_limit"]).to be_nil
      end

      it "allows up to three self-created loaner/active communicators, then 422s" do
        3.times do |i|
          create(:child_account, user: user, owner: user, status: "active",
                                 username: "p#{i}-#{SecureRandom.hex(2)}")
        end

        post "/api/child_accounts",
          params: { name: "Extra", username: "extra-#{SecureRandom.hex(3)}", status: "active", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/maximum/i)
      end
    end

    context "as a basic user" do
      let(:user) { create(:user, plan_type: "basic", created_at: 2.months.ago) }

      it "enforces the 2-communicator cap" do
        2.times do |i|
          create(:child_account, user: user, owner: user, status: "active",
                                 username: "b#{i}-#{SecureRandom.hex(2)}")
        end

        post "/api/child_accounts",
          params: { name: "Third", username: "third-#{SecureRandom.hex(3)}", status: "active", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end

      # Regression for PR #163 review: the pre-save valid? check fired
      # before the controller assigned passcode, so every non-sandbox
      # create 422'd with "Passcode is required..." regardless of the
      # password the user typed.
      it "actually creates a non-sandbox communicator when the password is supplied" do
        post "/api/child_accounts",
          params: { name: "First", username: "first-#{SecureRandom.hex(3)}", status: "active", password: "abcdef", password_confirmation: "abcdef" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:created), -> { response.body }
        account = ChildAccount.find_by(owner_id: user.id, status: "active")
        expect(account).to be_present
        expect(account.passcode).to eq("abcdef")
      end
    end
  end
end
