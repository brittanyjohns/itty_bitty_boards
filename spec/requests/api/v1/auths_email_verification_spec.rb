require "rails_helper"

# Signup no longer grants tokens up front — see
# drafts/2026-07-26-email-verification-design.md. `sign_up` sends a
# verification email; `email_signup` does not, because its welcome receipt
# already carries a magic login link that proves inbox ownership.
RSpec.describe "signup email verification", type: :request do
  describe "POST /api/v1/users (standard signup)" do
    def sign_up(email: "new@example.com")
      post "/api/v1/users",
           params: { email: email, password: "password123",
                     password_confirmation: "password123", name: "Sam" },
           as: :json
    end

    it "still signs the user in and returns a token" do
      sign_up
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["token"]).to be_present
    end

    it "creates the account unverified with a zero token balance" do
      sign_up
      user = User.find_by(email: "new@example.com")
      expect(user.email_verified?).to be(false)
      expect(user.tokens).to eq(0)
    end

    it "issues a verification token and sends the email" do
      expect {
        sign_up
      }.to have_enqueued_mail(UserMailer, :verify_email)

      expect(User.find_by(email: "new@example.com").email_verification_token).to be_present
    end

    it "still succeeds and returns a token when the verification mail enqueue raises (e.g. Redis is down)" do
      allow(UserMailer).to receive(:verify_email).and_raise(Redis::CannotConnectError, "Error connecting to Redis")

      sign_up

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["token"]).to be_present

      user = User.find_by(email: "new@example.com")
      expect(user).to be_present
      # Token generation runs before the mailer call, so it still lands even
      # though the enqueue itself blew up.
      expect(user.email_verification_token).to be_present
    end
  end

  describe "POST /api/v1/users/email_signup (paid-intent signup)" do
    it "does NOT send a verification email — the welcome receipt's magic link covers it" do
      expect {
        post "/api/v1/users/email_signup", params: { email: "paid@example.com" }, as: :json
      }.not_to have_enqueued_mail(UserMailer, :verify_email)
    end

    it "creates the account unverified with a zero balance" do
      post "/api/v1/users/email_signup", params: { email: "paid@example.com" }, as: :json

      user = User.find_by(email: "paid@example.com")
      expect(user.email_verified?).to be(false)
      expect(user.tokens).to eq(0)
    end
  end
end
