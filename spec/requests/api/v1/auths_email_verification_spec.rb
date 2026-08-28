require "rails_helper"

# Signup grants welcome tokens and the plan's AI credits up front
# (User#grant_signup_ai_allowance) — email verification no longer gates them.
# What verification still means is unchanged: both `sign_up` and
# `email_signup` send a verification email (task-7r), and `set_password` /
# invitation-accept no longer confers verified status (devise_invitable
# stamps confirmed_at on accept_invitation! regardless, which is not proof of
# inbox ownership — see the task-7r brief), so email_signup's welcome receipt
# alone can no longer be relied on to verify the address.
RSpec.describe "signup email verification", type: :request do
  # The Stripe gem raises Stripe::AuthenticationError client-side when no API
  # key is configured, before any request is made — so the WebMock stub for
  # api.stripe.com never sees it. CI has no key. Same stub as auth_spec.rb.
  before { allow(User).to receive(:create_stripe_customer).and_return("cus_test") }

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

    it "creates the account unverified but already funded" do
      sign_up
      user = User.find_by(email: "new@example.com")
      expect(user.email_verified?).to be(false)
      expect(user.tokens).to eq(User::WELCOME_TOKENS)
      expect(CreditService.balance(user)[:total]).to eq(
        CreditService.monthly_credits_for("free")
      )
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
    # Was "does NOT send" prior to task-7r: the welcome receipt's magic link
    # was assumed to prove inbox ownership via set_password, but set_password
    # doesn't prove that (see the task-7r brief) — so email_signup now sends
    # its own verification email, same as sign_up.
    it "sends a verification email" do
      expect {
        post "/api/v1/users/email_signup", params: { email: "paid@example.com" }, as: :json
      }.to have_enqueued_mail(UserMailer, :verify_email)

      expect(User.find_by(email: "paid@example.com").email_verification_token).to be_present
    end

    it "creates the account unverified but already funded" do
      post "/api/v1/users/email_signup", params: { email: "paid@example.com" }, as: :json

      user = User.find_by(email: "paid@example.com")
      expect(user.email_verified?).to be(false)
      expect(user.tokens).to eq(User::WELCOME_TOKENS)
      expect(CreditService.balance(user)[:total]).to be > 0
    end

    it "still succeeds and returns a token when the verification mail enqueue raises (e.g. Redis is down)" do
      allow(UserMailer).to receive(:verify_email).and_raise(Redis::CannotConnectError, "Error connecting to Redis")

      expect {
        post "/api/v1/users/email_signup", params: { email: "paid@example.com" }, as: :json
      }.to have_enqueued_mail(UserMailer, :welcome_email_receipt)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["token"]).to be_present

      user = User.find_by(email: "paid@example.com")
      expect(user).to be_present
      # By this point the account exists, is signed in, and has a Stripe
      # customer — the verification-mail rescue must not strand any of that,
      # and the welcome receipt still has to go out despite the failure.
    end
  end
end

RSpec.describe "verification is earned only by an emailed link", type: :request do
  before { allow(User).to receive(:create_stripe_customer).and_return("cus_test") }

  # THE security regression test for this task. Reaching set_password requires
  # only the session email_signup already handed out — no inbox access — so it
  # must not confer verified status, even though devise_invitable's
  # accept_invitation! stamps confirmed_at underneath us. Credits are no longer
  # what rides on this — the account is funded at signup either way — but
  # `email_verified_at` still has to mean "this inbox was opened".
  it "does NOT verify a user who sets a password without clicking an emailed link" do
    post "/api/v1/users/email_signup", params: { email: "nobody@example.com" }, as: :json
    user = User.find_by(email: "nobody@example.com")

    post "/api/v1/users/set_password",
         params: { password: "password123", password_confirmation: "password123" },
         headers: auth_headers(user), as: :json

    expect(response).to have_http_status(:ok)
    expect(user.reload.email_verified?).to be(false)
  end

  it "verifies on a successful temp login without re-granting" do
    user = FactoryBot.create(:user, email_verified_at: nil)
    user.update!(temp_login_token: "temptoken123", temp_login_expires_at: 1.hour.from_now)

    get "/api/temp-login/temptoken123"

    expect(response).to have_http_status(:ok)
    expect(user.reload.email_verified?).to be(true)
    expect(user.tokens).to eq(User::WELCOME_TOKENS)
  end

  it "does not double-grant when an already-verified user uses a temp login" do
    user = FactoryBot.create(:user, email_verified_at: 1.day.ago)
    user.update!(tokens: 2, temp_login_token: "temptoken456", temp_login_expires_at: 1.hour.from_now)

    get "/api/temp-login/temptoken456"

    expect(response).to have_http_status(:ok)
    expect(user.reload.tokens).to eq(2)
  end
end
