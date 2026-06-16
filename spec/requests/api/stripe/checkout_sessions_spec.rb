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
      expect(captured[:subscription_data][:trial_period_days]).to eq(14)
      # No-card reverse trial: lapses cancel cleanly instead of charging.
      expect(captured[:subscription_data][:trial_settings]).to eq(
        end_behavior: { missing_payment_method: "cancel" },
      )
      expect(captured[:metadata][:user_id]).to eq(user.id)
      expect(captured[:metadata][:plan_key]).to eq("basic")
      # When no promo, allow_promotion_codes is enabled
      expect(captured[:allow_promotion_codes]).to eq(true)
    end

    it "creates a Stripe customer when the user has none yet" do
      user.update!(stripe_customer_id: nil)

      # ensure_customer! delegates to User.create_stripe_customer, which
      # passes an options hash (not kwargs) — match accordingly.
      expect(Stripe::Customer).to receive(:create)
        .with({ email: user.email })
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

  describe "payment_method_collection (no-card reverse trial / A-B arm)" do
    let(:captured) { {} }

    before do
      user.update!(stripe_customer_id: "cus_existing")
      ENV.delete("STRIPE_PAYMENT_METHOD_COLLECTION")
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured.replace(params)
        OpenStruct.new(url: "https://stripe.test/x")
      end
    end

    it "defaults to no-card (if_required) for a Basic/Pro trial" do
      do_post.call({ plan_key: "basic" })
      expect(captured[:payment_method_collection]).to eq("if_required")
    end

    it "forces the card-required arm when params[:require_card] is true" do
      do_post.call({ plan_key: "basic", require_card: "true" })
      expect(captured[:payment_method_collection]).to eq("always")
    end

    it "forces the card-required arm via STRIPE_PAYMENT_METHOD_COLLECTION=always" do
      ENV["STRIPE_PAYMENT_METHOD_COLLECTION"] = "always"
      do_post.call({ plan_key: "basic" })
      expect(captured[:payment_method_collection]).to eq("always")
    ensure
      ENV.delete("STRIPE_PAYMENT_METHOD_COLLECTION")
    end

    it "lets the NOCC bypass win over the card-required arm" do
      ENV["STRIPE_PAYMENT_METHOD_COLLECTION"] = "always"
      do_post.call({ plan_key: "basic", promo_code: "NOCC" })
      expect(captured[:payment_method_collection]).to eq("if_required")
    ensure
      ENV.delete("STRIPE_PAYMENT_METHOD_COLLECTION")
    end

    it "records a trial_started analytics event with the arm metadata" do
      expect {
        do_post.call({ plan_key: "basic" })
      }.to change { AnalyticsEvent.for_event("trial_started").count }.by(1)

      event = AnalyticsEvent.for_event("trial_started").last
      expect(event.user_id).to eq(user.id)
      expect(event.metadata["plan_key"]).to eq("basic")
      expect(event.metadata["require_card"]).to eq(false)
      expect(event.metadata["payment_method_collection"]).to eq("if_required")
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

    def fake_session(status: "complete", plan_key: "basic_yearly", subscription: nil, user_id: user.id)
      OpenStruct.new(
        id: session_id,
        status: status,
        subscription: subscription,
        metadata: OpenStruct.new(user_id: user_id, plan_key: plan_key),
      )
    end

    def stub_session(**opts)
      allow(Stripe::Checkout::Session).to receive(:retrieve).with(session_id).and_return(fake_session(**opts))
    end

    it "on a completed session: normalizes plan_key, sets plan_status=active, enqueues Mailchimp" do
      stub_session(status: "complete", plan_key: "basic_yearly")

      expect {
        post "/api/stripe/update_user_from_session", params: { session_id: session_id }, headers: auth_headers(user)
      }.to change { MailchimpEventJob.jobs.size }.by(1)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.plan_type).to eq("basic") # normalized from basic_yearly
      expect(user.plan_status).to eq("active")
    end

    it "does NOT grant a plan for an incomplete/abandoned session (no payment)" do
      user.update!(plan_type: "free", plan_status: nil)
      stub_session(status: "open", plan_key: "pro")

      expect {
        post "/api/stripe/update_user_from_session", params: { session_id: session_id }, headers: auth_headers(user)
      }.not_to change { MailchimpEventJob.jobs.size }

      expect(response).to have_http_status(:ok)
      expect(user.reload.plan_type).to eq("free")
    end

    it "reflects the real subscription status (trialing), not a blanket 'active'" do
      sub = OpenStruct.new(
        status: "trialing",
        items: OpenStruct.new(data: [OpenStruct.new(price: OpenStruct.new(metadata: { "plan_type" => "pro" }))]),
      )
      allow(Stripe::Subscription).to receive(:retrieve).with("sub_123").and_return(sub)
      stub_session(status: "complete", plan_key: "basic", subscription: "sub_123")

      post "/api/stripe/update_user_from_session", params: { session_id: session_id }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.plan_type).to eq("pro")       # from the subscription's price metadata
      expect(user.plan_status).to eq("trialing") # status-correct, doesn't clobber the webhook
    end

    it "403s when the session belongs to a different user" do
      stub_session(status: "complete", user_id: 99_999_999, plan_key: "pro")

      expect {
        post "/api/stripe/update_user_from_session", params: { session_id: session_id }, headers: auth_headers(user)
      }.not_to change { user.reload.plan_type }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
