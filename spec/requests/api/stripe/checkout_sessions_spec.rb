require "rails_helper"

# Subscription-mode Checkout Session creation. Companion to
# spec/requests/api/stripe/checkout_sessions_topup_spec.rb which covers
# one-time top-up packs.
RSpec.describe "POST /api/stripe/checkout_sessions (subscription)", type: :request do

  # FRONT_END_URL is process-wide: examples here overwrite it, and a leaked
  # value changes what every other spec in the same shard renders for a public
  # board URL. Snapshot and restore rather than deleting — the real value comes
  # from config/application.yml.
  around do |example|
    original = ENV["FRONT_END_URL"]
    example.run
    original.nil? ? ENV.delete("FRONT_END_URL") : ENV["FRONT_END_URL"] = original
  end

  let(:user) { FactoryBot.create(:user) }

  let(:described_price_ids) do
    {
      "free" => nil,
      "basic" => "price_basic_monthly",
      "pro" => "price_pro_monthly",
      "basic_yearly" => "price_basic_yearly",
      "pro_yearly" => "price_pro_yearly",
      "partner_pro" => "price_partner_pro",
    }.freeze
  end

  before do
    # PLAN_PRICE_IDS is a frozen constant resolved at class load, so writing
    # to ENV in `before` blocks doesn't update it. Stub the constant directly
    # so the controller sees the test price IDs.
    stub_const("API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS", described_price_ids)
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

    # Production, 2026-08-03: a Free account could not upgrade to ANY plan.
    # Its stored customer no longer existed on the live Stripe key, so every
    # checkout 400'd on "No such customer" — with no way for the user to
    # recover. Verify the stale id instead of trusting it.
    it "recreates a stale Stripe customer instead of 400ing the checkout" do
      user.update!(stripe_customer_id: "cus_deleted_in_dashboard")

      allow(Stripe::Customer).to receive(:retrieve).and_raise(
        Stripe::InvalidRequestError.new(
          "No such customer: 'cus_deleted_in_dashboard'",
          "customer",
          code: "resource_missing",
        ),
      )
      expect(Stripe::Customer).to receive(:create)
        .with({ email: user.email })
        .and_return(OpenStruct.new(id: "cus_healed_456"))

      captured = nil
      expect(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://checkout.stripe.com/c/pay/cs_test_healed")
      end

      do_post.call({ plan_key: "basic" })

      expect(response).to have_http_status(:ok)
      expect(captured[:customer]).to eq("cus_healed_456")
      expect(user.reload.stripe_customer_id).to eq("cus_healed_456")
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

    # plan_key=free is also how the onboarding "Maybe later" skip is wired, so
    # it fires for people who never intended a plan change at all. Applying it
    # to an entitled account downgrades plan_type locally while the Stripe
    # subscription keeps billing. Real downgrades go through
    # subscriptions#cancel_subscription / #billing_portal.
    it "does not downgrade an active paid subscriber who lands on plan_key=free" do
      user.update!(plan_type: "pro", plan_status: "active")
      expect(Stripe::Checkout::Session).not_to receive(:create)

      do_post.call({ plan_key: "free" })

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["url"]).to end_with("/home")
      expect(user.reload.plan_type).to eq("pro")
      expect(user.plan_status).to eq("active")
    end

    it "does not downgrade an admin who lands on plan_key=free" do
      user.update!(role: "admin", plan_type: "pro", plan_status: "active")

      do_post.call({ plan_key: "free" })

      expect(response).to have_http_status(:ok)
      expect(user.reload.plan_type).to eq("pro")
    end

    it "still applies free for a cancelled subscriber, so stranded accounts heal" do
      user.update!(plan_type: "pro", plan_status: "canceled")

      do_post.call({ plan_key: "free" })

      expect(response).to have_http_status(:ok)
      expect(user.reload.plan_type).to eq("free")
      expect(user.plan_status).to eq("active")
    end

    it "rejects an unrecognized plan_key with a 400 instead of downgrading the user to free" do
      user.update!(plan_type: "pro", plan_status: "active")
      expect(Stripe::Checkout::Session).not_to receive(:create)

      do_post.call({ plan_key: "basic_5yr" })

      expect(response).to have_http_status(:bad_request)
      expect(user.reload.plan_type).to eq("pro")
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

  # Regression: the FOUNDING coupon's $50 minimum-amount restriction (the gate
  # that keeps it to yearly plans) was being validated against the no-card
  # trial's $0 checkout amount, so every promo'd checkout 400'd with
  # "does not meet the minimum amount requirement" (prod, 2026-07-07). Fix:
  # a promo checkout drops the trial so it carries the plan's real price.
  describe "promo code + no-card trial interaction (founding-family fix)" do
    let(:captured) { {} }
    let(:promo) { OpenStruct.new(id: "promo_founding_id") }

    before do
      user.update!(stripe_customer_id: "cus_existing")
      allow(Stripe::PromotionCode).to receive(:list)
        .with(hash_including(code: "FOUNDING", active: true))
        .and_return(OpenStruct.new(data: [promo]))
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured.replace(params)
        OpenStruct.new(url: "https://stripe.test/x")
      end
    end

    it "applies the promo as a discount and omits the trial so the coupon minimum is met" do
      do_post.call({ plan_key: "basic_yearly", promo_code: "FOUNDING" })

      expect(response).to have_http_status(:ok)
      expect(captured[:discounts]).to eq([{ promotion_code: "promo_founding_id" }])
      expect(captured).not_to have_key(:allow_promotion_codes)
      # No trial → the checkout carries the plan's real price ($80/$200 ≥ $50),
      # so a minimum-amount promotion code isn't redeemed against a $0 invoice.
      expect(captured).not_to have_key(:subscription_data)
    end

    it "does not record a trial_started event for a promo checkout (no trial began)" do
      expect {
        do_post.call({ plan_key: "basic_yearly", promo_code: "FOUNDING" })
      }.not_to change { AnalyticsEvent.for_event("trial_started").count }
    end

    it "still fires checkout_started for a promo checkout" do
      expect(PosthogService).to receive(:capture_for_user).with(
        an_object_having_attributes(id: user.id),
        "checkout_started",
        properties: hash_including(plan: "basic", billing_interval: "yearly"),
      )
      do_post.call({ plan_key: "basic_yearly", promo_code: "FOUNDING" })
    end

    it "keeps the 14-day no-card trial on a monthly plan when no promo is applied" do
      do_post.call({ plan_key: "basic" })

      expect(captured[:subscription_data][:trial_period_days]).to eq(14)
      expect(captured[:subscription_data][:trial_settings]).to eq(
        end_behavior: { missing_payment_method: "cancel" },
      )
      expect(captured[:allow_promotion_codes]).to eq(true)
    end

    # Second half of the same bug: a buyer who picks an annual plan from
    # /pricing WITHOUT the campaign link gets Stripe's own promo-code box
    # (allow_promotion_codes), and a trialing session's $0 amount-due makes
    # that box reject FOUNDING for not meeting the $50 minimum. Yearly
    # checkouts therefore skip the trial entirely.
    %w[basic_yearly pro_yearly].each do |plan_key|
      it "omits the trial for #{plan_key} even without a promo, so Stripe's promo box works" do
        do_post.call({ plan_key: plan_key })

        expect(response).to have_http_status(:ok)
        expect(captured).not_to have_key(:subscription_data)
        # Stripe's code box stays on — with the real annual price due today,
        # a minimum-restricted coupon now validates.
        expect(captured[:allow_promotion_codes]).to eq(true)
      end
    end

    it "does not record trial_started for a yearly checkout (no trial began)" do
      expect {
        do_post.call({ plan_key: "pro_yearly" })
      }.not_to change { AnalyticsEvent.for_event("trial_started").count }
    end

    it "still records trial_started for a monthly checkout" do
      expect {
        do_post.call({ plan_key: "basic" })
      }.to change { AnalyticsEvent.for_event("trial_started").count }.by(1)
    end
  end

  describe "server-side checkout_started analytics (itty_bitty_boards#452 / frontend #505)" do
    before do
      user.update!(stripe_customer_id: "cus_existing")
      allow(Stripe::Checkout::Session).to receive(:create).and_return(OpenStruct.new(url: "https://stripe.test/x"))
    end

    it "captures checkout_started with plan/billing_interval/source/kind, using the base plan for a yearly key" do
      expect(PosthogService).to receive(:capture_for_user).with(
        an_object_having_attributes(id: user.id),
        "checkout_started",
        properties: {
          plan: "pro",              # base plan, _yearly suffix stripped
          billing_interval: "yearly",
          kind: "subscription",
          source: "pricing_page",
        },
      )

      do_post.call({ plan_key: "pro_yearly", source: "pricing_page" })

      expect(response).to have_http_status(:ok)
    end

    it "defaults billing_interval to monthly and source to web_checkout when not provided" do
      expect(PosthogService).to receive(:capture_for_user).with(
        an_object_having_attributes(id: user.id),
        "checkout_started",
        properties: hash_including(plan: "basic", billing_interval: "monthly", source: "web_checkout"),
      )

      do_post.call({ plan_key: "basic" })
    end

    it "threads source + distinct_id into the Checkout Session (metadata + client_reference_id)" do
      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://stripe.test/x")
      end

      do_post.call({ plan_key: "basic", source: "onboarding" })

      expect(captured[:client_reference_id]).to eq(user.id.to_s)
      expect(captured[:metadata][:source]).to eq("onboarding")
    end

    it "does not fire checkout_started for the free-plan short-circuit" do
      expect(PosthogService).not_to receive(:capture_for_user)
      do_post.call({ plan_key: "free" })
    end
  end

  # A 5-Year license is a one-time payment; this endpoint only creates
  # subscription sessions (with a 14-day trial attached), so a license key
  # reaching it means the caller is about to sell the wrong product.
  describe "5-Year license keys are refused (never sold as a subscription)" do
    before { user.update!(stripe_customer_id: "cus_existing") }

    %w[basic_5yr pro_5yr].each do |license_key|
      it "400s for plan_key=#{license_key} and points at the license endpoint" do
        expect(Stripe::Checkout::Session).not_to receive(:create)

        do_post.call({ plan_key: license_key })

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["error"])
          .to eq("license plans use /api/stripe/checkout_sessions/license")
      end
    end

    it "refuses a license key even when it is present in PLAN_PRICE_IDS" do
      # The guard must not depend on the price lookup failing — that's the
      # accident this replaces.
      stub_const(
        "API::Stripe::CheckoutSessionsController::PLAN_PRICE_IDS",
        described_price_ids.merge("pro_5yr" => "price_pro_5yr_misconfigured").freeze
      )
      expect(Stripe::Checkout::Session).not_to receive(:create)

      do_post.call({ plan_key: "pro_5yr" })

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"])
        .to eq("license plans use /api/stripe/checkout_sessions/license")
    end

    it "fires no checkout_started and leaves the plan untouched" do
      expect(PosthogService).not_to receive(:capture_for_user)

      expect { do_post.call({ plan_key: "pro_5yr" }) }
        .not_to change { user.reload.attributes.values_at("plan_type", "paid_plan_type") }
    end

    it "still 400s the generic way for an unknown non-license key" do
      do_post.call({ plan_key: "gold" })

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("Unknown or unconfigured plan_key")
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
