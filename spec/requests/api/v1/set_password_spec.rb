require "rails_helper"

# Setting the initial password on a passwordless (invited) account.
# THE regression guard here: the password must actually authenticate
# afterwards. devise_invitable's valid_password? returns nil while
# invitation_token is present, so a naive update(password:) stores a
# password the user can never sign in with — both endpoints must route
# invited users through accept_invitation!.
RSpec.describe "set password endpoints", type: :request do
  let(:invited_user) { User.invite!(email: "invited@example.com", skip_invitation: true) }

  describe "POST /api/v1/users/set_password" do
    it "returns 401 when unauthenticated" do
      post "/api/v1/users/set_password", params: { password: "newpassword1", password_confirmation: "newpassword1" }
      expect(response).to have_http_status(:unauthorized)
    end

    context "for an invited passwordless user" do
      it "sets a password that actually signs in, and accepts the invitation" do
        post "/api/v1/users/set_password",
          params: { password: "newpassword1", password_confirmation: "newpassword1" },
          headers: auth_headers(invited_user)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["user"]["needs_password"]).to eq(false)

        invited_user.reload
        expect(invited_user.invitation_token).to be_nil
        expect(invited_user.invitation_accepted_at).to be_present
        expect(User.valid_credentials?("invited@example.com", "newpassword1")).to eq(invited_user)
      end

      it "returns 422 on confirmation mismatch and stays passwordless + invited" do
        post "/api/v1/users/set_password",
          params: { password: "newpassword1", password_confirmation: "different1" },
          headers: auth_headers(invited_user)

        expect(response).to have_http_status(:unprocessable_content)
        invited_user.reload
        expect(invited_user.invitation_token).to be_present
        expect(User.valid_credentials?("invited@example.com", "newpassword1")).to be_nil
      end

      it "returns 422 on a too-short password and stays passwordless + invited" do
        post "/api/v1/users/set_password",
          params: { password: "x", password_confirmation: "x" },
          headers: auth_headers(invited_user)

        expect(response).to have_http_status(:unprocessable_content)
        invited_user.reload
        expect(invited_user.invitation_token).to be_present
        expect(User.valid_credentials?("invited@example.com", "x")).to be_nil
      end
    end

    context "for a user who already has a password" do
      let(:user) { FactoryBot.create(:user, password: "password123") }

      it "returns 422 password_already_set" do
        post "/api/v1/users/set_password",
          params: { password: "newpassword1", password_confirmation: "newpassword1" },
          headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error_code"]).to eq("password_already_set")
      end
    end
  end

  # Legacy endpoint (force-password-reset flow) — patched for the same
  # invited-user trap in this change.
  describe "POST /api/set-password" do
    it "sets a sign-in-able password for an invited user" do
      post "/api/set-password",
        params: { password: "newpassword1", password_confirmation: "newpassword1" },
        headers: auth_headers(invited_user)

      expect(response).to have_http_status(:ok)
      invited_user.reload
      expect(invited_user.invitation_token).to be_nil
      expect(User.valid_credentials?("invited@example.com", "newpassword1")).to eq(invited_user)
    end

    it "still works for a non-invited user changing their password" do
      user = FactoryBot.create(:user, password: "password123")
      post "/api/set-password",
        params: { password: "newpassword9", password_confirmation: "newpassword9" },
        headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(User.valid_credentials?(user.email, "newpassword9")).to eq(user)
    end
  end
end
