require "rails_helper"

# Every new WEB signup picks Basic or Pro and is put straight into a 14-day
# no-card Stripe trial — no Checkout redirect, since a trial charges nothing and
# there is nothing for Stripe's hosted page to collect. Mobile keeps landing on
# Free (App Store / Play require IAP for subscriptions).
RSpec.describe "Signup starts a Stripe trial", type: :request do
  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_test_trial")
    allow(MailchimpEventJob).to receive(:perform_async)
    allow(PosthogService).to receive(:capture_for_user)
    allow(AdminMailer).to receive(:plan_change_email).and_return(double(deliver_later: true))
    stub_const("ENV", ENV.to_hash.merge(
      "STRIPE_PRICE_BASIC" => "price_basic",
      "STRIPE_PRICE_PRO" => "price_pro",
    ))
    allow_any_instance_of(User).to receive(:ensure_stripe_customer!).and_return("cus_test_trial")
    allow(Stripe::Subscription).to receive(:create).and_return(
      OpenStruct.new(id: "sub_new", status: "trialing", trial_end: 14.days.from_now.to_i),
    )
  end

  let(:params) do
    {
      email: "trialist@example.com",
      password: "password123",
      password_confirmation: "password123",
      name: "New Trialist",
    }
  end

  def signed_up_user
    User.find_by(email: "trialist@example.com")
  end

  describe "POST /api/v1/users" do
    it "puts a Basic pick straight into a trialing subscription" do
      post "/api/v1/users", params: params.merge(plan_type: "basic")

      expect(response).to have_http_status(:ok)
      user = signed_up_user
      expect(user.plan_type).to eq("basic")
      expect(user.plan_status).to eq("trialing")
      expect(user.stripe_subscription_id).to eq("sub_new")
    end

    it "puts a Pro pick on the pro price" do
      expect(Stripe::Subscription).to receive(:create).with(
        hash_including(items: [{ price: "price_pro", quantity: 1 }], trial_period_days: 14),
      ).and_return(OpenStruct.new(id: "sub_pro", status: "trialing", trial_end: 14.days.from_now.to_i))

      post "/api/v1/users", params: params.merge(plan_type: "pro")

      expect(signed_up_user.plan_type).to eq("pro")
    end

    # The response is rendered before the Stripe webhook can land, so the
    # optimistic local mirror is what the frontend actually reads.
    it "reports the trial in the signup response, not a stale free plan" do
      post "/api/v1/users", params: params.merge(plan_type: "pro")

      body = JSON.parse(response.body)
      expect(body.dig("user", "plan_type")).to eq("pro")
      expect(body["token"]).to be_present
    end

    it "leaves a mobile signup on Free without touching Stripe" do
      expect(Stripe::Subscription).not_to receive(:create)

      post "/api/v1/users", params: params.merge(plan_type: "pro", platform: "ios")

      expect(response).to have_http_status(:ok)
      expect(signed_up_user.plan_type).to eq("free")
    end

    # Older frontends send the raw viewType string as plan_type.
    it "leaves an unrecognized plan_type on Free" do
      expect(Stripe::Subscription).not_to receive(:create)

      post "/api/v1/users", params: params.merge(plan_type: "marketing")

      expect(response).to have_http_status(:ok)
      expect(signed_up_user.plan_type).to eq("free")
    end

    it "leaves a signup with no plan_type on Free" do
      expect(Stripe::Subscription).not_to receive(:create)

      post "/api/v1/users", params: params

      expect(signed_up_user.plan_type).to eq("free")
    end

    it "still creates a usable account when Stripe is down" do
      allow(Stripe::Subscription).to receive(:create)
        .and_raise(Stripe::APIConnectionError.new("stripe is down"))

      post "/api/v1/users", params: params.merge(plan_type: "pro")

      expect(response).to have_http_status(:ok)
      user = signed_up_user
      expect(user).to be_present
      expect(user.plan_type).to eq("free")
      expect(JSON.parse(response.body)["token"]).to be_present
    end

    describe "the welcome email" do
      it "is the plan welcome, not the Free one, for a trialist" do
        expect_any_instance_of(User).to receive(:send_plan_welcome_email_once!).with("basic", source: "signup_trial")
        expect_any_instance_of(User).not_to receive(:send_welcome_email).with("free")

        post "/api/v1/users", params: params.merge(plan_type: "basic")
      end

      it "is still the Free one when no trial started" do
        expect_any_instance_of(User).to receive(:send_welcome_email).with("free")

        post "/api/v1/users", params: params
      end
    end

    it "does not disturb the partner_pro path" do
      expect(Stripe::Subscription).not_to receive(:create)
      allow(User).to receive(:handle_new_partner_pro_subscription)

      post "/api/v1/users", params: params.merge(plan_type: "partner_pro")

      expect(signed_up_user.plan_type).to eq("partner_pro")
    end
  end

  describe "POST /api/v1/users/email_signup" do
    it "starts the trial for the plan the pricing CTA carried" do
      post "/api/v1/users/email_signup", params: { email: "cta@example.com", plan_type: "pro" }

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: "cta@example.com")
      expect(user.plan_type).to eq("pro")
      expect(user.plan_status).to eq("trialing")
    end

    it "leaves an email-only signup with no plan on Free" do
      expect(Stripe::Subscription).not_to receive(:create)

      post "/api/v1/users/email_signup", params: { email: "noplan@example.com" }

      expect(User.find_by(email: "noplan@example.com").plan_type).to eq("free")
    end
  end

  describe "POST /api/v1/auths/google" do
    before do
      allow(GoogleIdTokenVerifier).to receive(:verify)
        .and_return(GoogleIdTokenVerifier::Result.new(sub: "g-sub-1", email: "gtrialist@example.com"))
    end

    it "starts the trial for a brand-new Google account" do
      post "/api/v1/auths/google", params: { id_token: "valid", plan_type: "basic" }

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: "gtrialist@example.com")
      expect(user.plan_type).to eq("basic")
      expect(user.plan_status).to eq("trialing")
    end

    # This one endpoint both signs up and signs in — starting a trial
    # unconditionally would create a second subscription for a returning
    # customer.
    it "does not start a trial for a returning customer" do
      create(:user, email: "gtrialist@example.com", provider: "google", uid: "g-sub-1")
      expect(Stripe::Subscription).not_to receive(:create)

      post "/api/v1/auths/google", params: { id_token: "valid", plan_type: "pro" }

      expect(response).to have_http_status(:ok)
      expect(User.find_by(email: "gtrialist@example.com").plan_type).to eq("free")
    end
  end
end
