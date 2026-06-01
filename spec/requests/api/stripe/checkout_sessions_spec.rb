require "rails_helper"

# Subscription-mode Checkout Session creation. Companion to
# spec/requests/api/stripe/checkout_sessions_topup_spec.rb which covers
# one-time top-up packs.
RSpec.describe "POST /api/stripe/checkout_sessions (subscription)", type: :request do
  let(:user) { FactoryBot.create(:user) }

  before do
    # PLAN_PRICE_IDS is a frozen constant resolved at class load, so writing
    # to ENV in `before` blocks doesn't update it. Stub the constant directly
    # so the controller sees the test price IDs.
    stub_const(
      "API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS",
      {
        "free" => nil,
        "basic" => "price_basic_monthly",
        "pro" => "price_pro_monthly",
        "basic_yearly" => "price_basic_yearly",
        "pro_yearly" => "price_pro_yearly",
        "partner_pro" => "price_partner_pro",
      }.freeze
    )
    ENV["STRIPE_PARTNER_PILOT_PROMO"] = "PARTNERPILOT26"
    # The controller calls Stripe::Customer.create / Stripe::PromotionCode.list
    # for the partner promo path; stub anything we don't explicitly handle.
    allow(Stripe::PromotionCode).to receive(:list).and_return(OpenStruct.new(data: []))
  end

  # NOTE: don't name a helper `create_session` — it shadows
  # ActionDispatch::Integration::Runner#create_session and breaks `post`.
  let(:do_post) do
    ->(params_hash) { post "/api/stripe/checkout_sessions", params: params_hash, headers: auth_headers(user) }
  end

  describe "#create (subscription mode)" do
    it "creates a 14-day-trial subscription Checkout Session for plan_key=basic" do
      user.update!(stripe_customer_id: "cus_existing")

      captured = nil
      expect(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://checkout.stripe.com/c/pay/cs_test_basic")
      end

      do_post.call({ plan_key: "basic" })

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["url"]).to match(%r{checkout\.stripe\.com})
      expect(captured[:mode]).to eq("subscription")
      expect(captured[:customer]).to eq("cus_existing")
      expect(captured[:line_items]).to eq([{ price: "price_basic_monthly", quantity: 1 }])
      expect(captured[:subscription_data]).to eq(trial_period_days: 14)
      expect(captured[:metadata][:user_id]).to eq(user.id)
      expect(captured[:metadata][:plan_key]).to eq("basic")
      # When no promo, allow_promotion_codes is enabled
      expect(captured[:allow_promotion_codes]).to eq(true)
    end

    it "creates a Stripe customer when the user has none yet" do
      user.update!(stripe_customer_id: nil)

      expect(Stripe::Customer).to receive(:create)
        .with(email: user.email)
        .and_return(OpenStruct.new(id: "cus_new_123"))
      expect(Stripe::Checkout::Session).to receive(:create).and_return(OpenStruct.new(url: "https://stripe.test/x"))

      do_post.call({ plan_key: "basic" })

      expect(user.reload.stripe_customer_id).to eq("cus_new_123")
    end

    it "records paid_plan_type on the user after creating the session" do
      user.update!(stripe_customer_id: "cus_existing")
      allow(Stripe::Checkout::Session).to receive(:create).and_return(OpenStruct.new(url: "https://stripe.test/x"))

      expect {
        do_post.call({ plan_key: "pro" })
      }.to change { user.reload.paid_plan_type }.to("pro")
    end

    it "short-circuits free plan to /home without calling Stripe" do
      expect(Stripe::Checkout::Session).not_to receive(:create)

      do_post.call({ plan_key: "free" })

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["url"]).to end_with("/home")
      expect(user.reload.plan_type).to eq("free")
      expect(user.plan_status).to eq("active")
    end

    it "auto-applies the partner pilot promo code for plan_key=partner_pro" do
      user.update!(stripe_customer_id: "cus_partner")
      promo = OpenStruct.new(id: "promo_partner_id")
      expect(Stripe::PromotionCode).to receive(:list)
        .with(hash_including(code: "PARTNERPILOT26", active: true))
        .and_return(OpenStruct.new(data: [promo]))

      captured = nil
      expect(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://stripe.test/x")
      end

      do_post.call({ plan_key: "partner_pro" })

      expect(captured[:discounts]).to eq([{ promotion_code: "promo_partner_id" }])
      expect(captured).not_to have_key(:allow_promotion_codes)
    end

    it "is auth-gated (no token → unauthorized)" do
      post "/api/stripe/checkout_sessions", params: { plan_key: "basic" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 400 when Stripe raises" do
      user.update!(stripe_customer_id: "cus_existing")
      allow(Stripe::Checkout::Session).to receive(:create).and_raise(Stripe::StripeError.new("nope"))

      do_post.call({ plan_key: "basic" })

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("Failed to create checkout session")
    end
  end

  describe "frontend_base_url redirect safety (ALLOWED_FRONTEND_HOSTS)" do
    before do
      user.update!(stripe_customer_id: "cus_existing")
      allow(Stripe::Checkout::Session).to receive(:create) { |p| OpenStruct.new(url: p[:success_url]) }
    end

    it "uses request Origin when on a trusted host (speakanyway.com)" do
      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://stripe.test/x")
      end

      post "/api/stripe/checkout_sessions",
           params: { plan_key: "basic" },
           headers: auth_headers(user).merge("HTTP_ORIGIN" => "https://app.speakanyway.com")

      expect(captured[:success_url]).to start_with("https://app.speakanyway.com")
    end

    it "ignores Origin from an untrusted host and falls back to ENV['FRONT_END_URL']" do
      ENV["FRONT_END_URL"] = "https://fallback.example.com"
      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://stripe.test/x")
      end

      post "/api/stripe/checkout_sessions",
           params: { plan_key: "basic" },
           headers: auth_headers(user).merge("HTTP_ORIGIN" => "https://evil.example.com")

      expect(captured[:success_url]).to start_with("https://fallback.example.com")
    end
  end

  describe "#update_user_from_session" do
    let(:session_id) { "cs_test_session_xyz" }
    let(:fake_session) do
      OpenStruct.new(
        id: session_id,
        metadata: OpenStruct.new(user_id: user.id, plan_key: "basic_yearly"),
      )
    end

    before do
      allow(Stripe::Checkout::Session).to receive(:retrieve).with(session_id).and_return(fake_session)
    end

    it "normalizes plan_key, sets plan_status=active, and enqueues a Mailchimp event" do
      expect {
        post "/api/stripe/update_user_from_session",
             params: { session_id: session_id },
             headers: auth_headers(user)
      }.to change { MailchimpEventJob.jobs.size }.by(1)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.plan_type).to eq("basic") # normalized from basic_yearly
      expect(user.plan_status).to eq("active")
    end

    it "404s when the session metadata.user_id resolves to no user" do
      bad_session = OpenStruct.new(id: session_id, metadata: OpenStruct.new(user_id: 99_999_999, plan_key: "basic"))
      allow(Stripe::Checkout::Session).to receive(:retrieve).with(session_id).and_return(bad_session)

      post "/api/stripe/update_user_from_session",
           params: { session_id: session_id },
           headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
    end
  end
end
