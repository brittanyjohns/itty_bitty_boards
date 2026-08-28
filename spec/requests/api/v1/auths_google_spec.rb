require "rails_helper"

# Phase 1 of social sign-in: Google only, parent User model.
# See .claude-notes/social-sign-in-handoff.md for the design decisions.
RSpec.describe "POST /api/v1/auths/google", type: :request do
  let(:google_sub) { "1234567890" }
  let(:google_email) { "signer@example.com" }

  def stub_google_verification(sub: google_sub, email: google_email)
    allow(GoogleIdTokenVerifier).to receive(:verify)
      .with("valid-id-token")
      .and_return(GoogleIdTokenVerifier::Result.new(sub: sub, email: email))
  end

  def stub_invalid_google_verification
    allow(GoogleIdTokenVerifier).to receive(:verify).and_return(nil)
  end

  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_google")
    allow(MailchimpEventJob).to receive(:perform_async)
    allow(PosthogService).to receive(:capture_for_user)
  end

  def do_post(params)
    post "/api/v1/auths/google", params: params
  end

  describe "new Google sign-in, no existing account" do
    before { stub_google_verification }

    it "creates a User with provider/uid, no password, verified email, and returns a token" do
      expect {
        do_post(id_token: "valid-id-token")
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: google_email)
      expect(user.provider).to eq("google")
      expect(user.uid).to eq(google_sub)
      expect(user.valid_password?("anything")).to be_falsey
      expect(user.email_verified_at).to be_present

      body = JSON.parse(response.body)
      expect(body["token"]).to eq(user.authentication_token)
      expect(body["user"]["id"]).to eq(user.id)
      # The frontend routes new accounts to /onboarding (the plan picker) and
      # returning customers to their dashboard. Sending a returning customer to
      # the picker was one click from a downgrade, so this flag is load-bearing.
      expect(body["is_new_user"]).to be(true)
    end

    it "runs signup side effects (Stripe customer, Mailchimp, PostHog)" do
      do_post(id_token: "valid-id-token")

      user = User.find_by(email: google_email)
      expect(User).to have_received(:create_stripe_customer).with(google_email)
      expect(MailchimpEventJob).to have_received(:perform_async).with(user.id, "sign_up")
      expect(PosthogService).to have_received(:capture_for_user).with(
        user, "user_signed_up",
        properties: hash_including(signup_method: "google")
      )
    end

    it "grants the welcome tokens on signup" do
      do_post(id_token: "valid-id-token")

      user = User.find_by(email: google_email)
      expect(user.tokens).to eq(User::WELCOME_TOKENS)
    end
  end

  describe "Google sign-in, email matches an existing password account" do
    let!(:existing) { FactoryBot.create(:user, email: google_email) }

    before { stub_google_verification }

    it "auto-links provider/uid onto the existing User without creating a duplicate" do
      expect {
        do_post(id_token: "valid-id-token")
      }.not_to change(User, :count)

      existing.reload
      expect(existing.provider).to eq("google")
      expect(existing.uid).to eq(google_sub)
      expect(existing.email_verified_at).to be_present

      body = JSON.parse(response.body)
      expect(body["token"]).to eq(existing.authentication_token)
      # Auto-linked an account that already existed — not a signup.
      expect(body["is_new_user"]).to be(false)
    end

    it "does not touch the plan of the account it links to" do
      existing.update!(plan_type: "pro", plan_status: "active")

      do_post(id_token: "valid-id-token")

      expect(existing.reload.plan_type).to eq("pro")
      expect(existing.plan_status).to eq("active")
    end

    it "does not run signup side effects for an auto-linked account" do
      do_post(id_token: "valid-id-token")

      expect(User).not_to have_received(:create_stripe_customer)
      expect(MailchimpEventJob).not_to have_received(:perform_async).with(existing.id, "sign_up")
    end
  end

  describe "Google sign-in, provider+uid already on file" do
    let!(:existing) { FactoryBot.create(:user, email: google_email, provider: "google", uid: google_sub, email_verified_at: Time.current) }

    before { stub_google_verification }

    it "signs in directly without re-running signup side effects" do
      expect {
        do_post(id_token: "valid-id-token")
      }.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(User).not_to have_received(:create_stripe_customer)
      expect(MailchimpEventJob).not_to have_received(:perform_async).with(existing.id, "sign_up")

      body = JSON.parse(response.body)
      expect(body["token"]).to eq(existing.reload.authentication_token)
      expect(body["is_new_user"]).to be(false)
    end
  end

  describe "invalid or expired Google ID token" do
    before { stub_invalid_google_verification }

    it "returns 401 and creates no User" do
      expect {
        do_post(id_token: "garbage")
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "does not modify an existing User" do
      user = FactoryBot.create(:user, email: google_email)

      do_post(id_token: "garbage")

      expect(user.reload.provider).to be_nil
    end
  end

  describe "locked account" do
    let!(:existing) { FactoryBot.create(:user, email: google_email, provider: "google", uid: google_sub, locked: true) }

    before { stub_google_verification }

    it "returns 401 and does not sign in" do
      do_post(id_token: "valid-id-token")

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "regression: existing password login and ChildAccount login are unaffected" do
    it "password login still works" do
      user = FactoryBot.create(:user, email: "password_user@example.com", password: "password123", password_confirmation: "password123")

      post "/api/v1/users/sign_in", params: { email: user.email, password: "password123" }

      expect(response).to have_http_status(:ok)
    end
  end
end
