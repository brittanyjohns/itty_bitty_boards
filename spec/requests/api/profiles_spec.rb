require "rails_helper"

RSpec.describe "API::Profiles", type: :request do
  describe "POST /api/profiles (MySpeak ID limit)" do
    # New users within TRAIL_PERIOD (14 days) get auto-bumped to basic_trial,
    # which `paid_plan?` treats as paid. To test the true Free state, bypass
    # callbacks with update_columns so plan_type stays "free".
    let(:free_user) do
      user = FactoryBot.create(:user)
      user.update_columns(plan_type: "free", created_at: 30.days.ago)
      user
    end
    let(:pro_user) { FactoryBot.create(:user, plan_type: "pro") }

    let(:create_params) do
      { profile: { username: "pat-#{SecureRandom.hex(2)}" } }
    end

    context "as a Free user" do
      it "allows creating the first MySpeak ID" do
        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        }.to change { Profile.where(profileable: free_user).count }.by(1)
        expect(response).to have_http_status(:created)
      end

      it "rejects the second MySpeak ID with 403 and a clear error code" do
        Profile.create!(
          profileable: free_user,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        post "/api/profiles", params: create_params, headers: auth_headers(free_user)

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("myspeak_id_limit_reached")
        expect(body["limit"]).to eq(1)
        expect(body["count"]).to eq(1)
        expect(body["message"]).to include("Free")
      end

      it "counts a Profile attached to one of the user's communicator accounts toward the limit" do
        child = FactoryBot.create(:child_account, user: free_user, owner: free_user)
        Profile.create!(
          profileable: child,
          username: "child-#{SecureRandom.hex(2)}",
          slug: "child-#{SecureRandom.hex(2)}",
        )

        post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("myspeak_id_limit_reached")
      end
    end

    context "as a Pro user" do
      it "is not limited" do
        Profile.create!(
          profileable: pro_user,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(pro_user)
        }.to change { Profile.where(profileable: pro_user).count }.by(1)
        expect(response).to have_http_status(:created)
      end
    end

    context "as an admin on the Free plan" do
      it "bypasses the limit" do
        admin = FactoryBot.create(:user, role: "admin")
        admin.update_columns(plan_type: "free", created_at: 30.days.ago)
        Profile.create!(
          profileable: admin,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(admin)
        }.to change { Profile.where(profileable: admin).count }.by(1)
        expect(response).to have_http_status(:created)
      end
    end
  end
end
