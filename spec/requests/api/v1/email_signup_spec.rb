require "rails_helper"

# Email-only signup for the paid-intent path (frictionless paid signup,
# itty-bitty-frontend#367): one email field, passwordless account via
# invite!, signed in immediately, straight to checkout.
RSpec.describe "POST /api/v1/users/email_signup", type: :request do
  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_email_signup")
    allow(MailchimpEventJob).to receive(:perform_async)
  end

  def do_post(params)
    post "/api/v1/users/email_signup", params: params
  end

  describe "happy path" do
    it "creates a passwordless invited user on the free plan with initial credits" do
      expect {
        do_post(email: "buyer@example.com")
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: "buyer@example.com")
      # devise_invitable assigns a random password on invite!, so "passwordless"
      # means a pending invitation: no password works until it's accepted.
      expect(user.invitation_token).to be_present
      expect(user.invitation_accepted_at).to be_nil
      expect(user.valid_password?("anything")).to be_falsey
      expect(user.plan_type).to eq("free")
      expect(user.plan_credits_balance.to_i).to be > 0
    end

    it "returns the same envelope as sign_up, with needs_password true" do
      do_post(email: "buyer@example.com")

      body = JSON.parse(response.body)
      user = User.find_by(email: "buyer@example.com")
      expect(body["token"]).to eq(user.authentication_token)
      expect(body["user"]["id"]).to eq(user.id)
      expect(body["user"]["needs_password"]).to eq(true)
      expect(body).not_to have_key("raw_invitation_token")
    end

    it "normalizes the email" do
      do_post(email: "  Buyer@Example.COM ")
      expect(response).to have_http_status(:ok)
      expect(User.find_by(email: "buyer@example.com")).to be_present
    end

    it "creates and persists a Stripe customer" do
      do_post(email: "buyer@example.com")
      expect(User).to have_received(:create_stripe_customer).with("buyer@example.com")
      expect(User.find_by(email: "buyer@example.com").stripe_customer_id).to eq("cus_email_signup")
    end

    it "still succeeds (200) and returns the user when Stripe customer creation fails" do
      # Regression: a Stripe hiccup must not 500 after invite! has persisted the
      # user — that stranded created accounts and the frontend fell back to the
      # full sign-up form, which then failed with "email taken". The customer is
      # lazily ensured at checkout instead.
      allow(User).to receive(:create_stripe_customer)
        .and_raise(Stripe::APIConnectionError.new("boom"))

      expect {
        do_post(email: "buyer@example.com")
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: "buyer@example.com")
      body = JSON.parse(response.body)
      expect(body["token"]).to eq(user.authentication_token)
      expect(body["user"]["id"]).to eq(user.id)
      expect(user.stripe_customer_id).to be_nil
    end

    it "does not set paid_plan_type (checkout owns it)" do
      do_post(email: "buyer@example.com")
      expect(User.find_by(email: "buyer@example.com").paid_plan_type).to be_blank
    end

    %w[ios android].each do |platform|
      it "skips Stripe customer creation for platform=#{platform}" do
        do_post(email: "buyer@example.com", platform: platform)
        expect(response).to have_http_status(:ok)
        expect(User).not_to have_received(:create_stripe_customer)
        expect(User.find_by(email: "buyer@example.com").stripe_customer_id).to be_nil
      end
    end

    it "sends the plan-neutral receipt email with the raw invitation token (magic link)" do
      mail = double(deliver_later: true)
      captured_args = nil
      allow(UserMailer).to receive(:welcome_email_receipt) do |*args|
        captured_args = args
        mail
      end
      allow(AdminMailer).to receive(:new_user_email).and_return(double(deliver_later: true))

      do_post(email: "buyer@example.com")

      expect(captured_args[0].email).to eq("buyer@example.com")
      expect(captured_args[1]).to be_a(String)
      expect(captured_args[1]).to be_present
    end

    it "does NOT send the Free welcome email at signup (plan unknown until checkout)" do
      allow(UserMailer).to receive(:welcome_free_email).and_call_original
      allow(UserMailer).to receive(:welcome_email_receipt).and_return(double(deliver_later: true))
      allow(AdminMailer).to receive(:new_user_email).and_return(double(deliver_later: true))

      do_post(email: "buyer@example.com")

      expect(UserMailer).not_to have_received(:welcome_free_email)
    end

    it "marks receipt_email_sent but not welcome_email_sent" do
      allow(UserMailer).to receive(:welcome_email_receipt).and_return(double(deliver_later: true))
      allow(AdminMailer).to receive(:new_user_email).and_return(double(deliver_later: true))

      do_post(email: "buyer@example.com")
      user = User.find_by(email: "buyer@example.com")

      expect(user.settings["receipt_email_sent"]).to eq(true)
      expect(user.settings["welcome_email_sent"]).not_to eq(true)
    end

    it "enqueues the Mailchimp welcome journey and sign_up event" do
      do_post(email: "buyer@example.com")
      user = User.find_by(email: "buyer@example.com")
      expect(MailchimpEventJob).to have_received(:perform_async)
        .with(user.id, "journey", { "journey_key" => "welcome" })
      expect(MailchimpEventJob).to have_received(:perform_async).with(user.id, "sign_up")
    end
  end

  describe "duplicate email" do
    let!(:existing) { FactoryBot.create(:user, email: "taken@example.com") }

    it "returns 422 with the email_taken error_code" do
      expect {
        do_post(email: "taken@example.com")
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error_code"]).to eq("email_taken")
      expect(body["error"]).to eq("Email has already been taken")
    end

    it "returns the same 422 body when the unique index catches a race" do
      allow(User).to receive(:exists?).and_return(false)
      allow(User).to receive(:invite!).and_raise(ActiveRecord::RecordNotUnique)

      do_post(email: "taken@example.com")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error_code"]).to eq("email_taken")
    end
  end

  describe "invalid email" do
    ["", "   ", "not-an-email", "two@at@signs"].each do |bad|
      it "returns 422 for #{bad.inspect}" do
        expect {
          do_post(email: bad)
        }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to be_present
      end
    end
  end
end
