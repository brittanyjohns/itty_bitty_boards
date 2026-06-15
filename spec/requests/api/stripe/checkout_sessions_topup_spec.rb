require "rails_helper"

RSpec.describe "POST /api/stripe/checkout_sessions/topup", type: :request do
  let(:user) { FactoryBot.create(:user) }

  before do
    ENV["STRIPE_PRICE_TOPUP_SMALL"] = "price_topup_small"
    ENV["STRIPE_PRICE_TOPUP_MEDIUM"] = "price_topup_medium"
    ENV["STRIPE_PRICE_TOPUP_LARGE"] = "price_topup_large"
  end

  it "creates a one-time Checkout Session with topup metadata and returns its url" do
    user.update!(stripe_customer_id: "cus_existing")

    captured = nil
    expect(Stripe::Checkout::Session).to receive(:create) do |params|
      captured = params
      OpenStruct.new(url: "https://checkout.stripe.com/c/pay/cs_test_topup_small")
    end

    post "/api/stripe/checkout_sessions/topup",
         params: { pack_key: "small" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["url"]).to match(%r{checkout\.stripe\.com})

    expect(captured[:mode]).to eq("payment")
    expect(captured[:customer]).to eq("cus_existing")
    expect(captured[:line_items]).to eq([{ price: "price_topup_small", quantity: 1 }])
    expect(captured[:metadata][:kind]).to eq("topup")
    expect(captured[:metadata][:pack_key]).to eq("small")
    expect(captured[:metadata][:credit_amount]).to eq(100)
    expect(captured[:metadata][:user_id]).to eq(user.id)
    # Regression guard: Stripe rejects `payment_method_collection` on
    # mode=payment Checkout Sessions with "You can only set
    # `payment_method_collection` if there are recurring prices."
    expect(captured).not_to have_key(:payment_method_collection)
  end

  it "scales credit_amount by quantity" do
    user.update!(stripe_customer_id: "cus_q")

    captured = nil
    allow(Stripe::Checkout::Session).to receive(:create) do |params|
      captured = params
      OpenStruct.new(url: "https://checkout.stripe.com/c/pay/cs_test_q")
    end

    post "/api/stripe/checkout_sessions/topup",
         params: { pack_key: "medium", quantity: 3 },
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(captured[:line_items].first[:quantity]).to eq(3)
    expect(captured[:metadata][:credit_amount]).to eq(1500) # 500 * 3
  end

  it "creates a stripe customer if the user does not have one yet" do
    expect(user.stripe_customer_id).to be_blank
    expect(Stripe::Customer).to receive(:create).with({ email: user.email }).and_return(OpenStruct.new(id: "cus_new"))
    expect(Stripe::Checkout::Session).to receive(:create).and_return(OpenStruct.new(url: "https://example/cs"))

    post "/api/stripe/checkout_sessions/topup",
         params: { pack_key: "large" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(user.reload.stripe_customer_id).to eq("cus_new")
  end

  it "rejects an unknown pack_key" do
    post "/api/stripe/checkout_sessions/topup",
         params: { pack_key: "ginormous" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to match(/Unknown/i)
  end

  it "rejects when the configured Price ID is blank" do
    ENV["STRIPE_PRICE_TOPUP_SMALL"] = ""

    post "/api/stripe/checkout_sessions/topup",
         params: { pack_key: "small" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
  end

  it "returns 401 when unauthenticated" do
    post "/api/stripe/checkout_sessions/topup", params: { pack_key: "small" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 400 when Stripe raises" do
    user.update!(stripe_customer_id: "cus_existing")
    allow(Stripe::Checkout::Session).to receive(:create).and_raise(Stripe::APIError.new("boom"))

    post "/api/stripe/checkout_sessions/topup",
         params: { pack_key: "small" },
         headers: auth_headers(user)

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to match(/Failed/i)
  end

  describe "success_url / cancel_url derivation" do
    let(:netlify_origin) { "https://deploy-preview-42--speakanyway-app.netlify.app" }

    before { user.update!(stripe_customer_id: "cus_origin") }

    it "uses an allowed Netlify preview Origin for success_url" do
      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://example/cs")
      end

      post "/api/stripe/checkout_sessions/topup",
           params: { pack_key: "small" },
           headers: auth_headers(user).merge("HTTP_ORIGIN" => netlify_origin)

      expect(captured[:success_url]).to start_with("#{netlify_origin}/billing/success?session_id={CHECKOUT_SESSION_ID}&type=topup&credits=100")
      expect(captured[:cancel_url]).to eq("#{netlify_origin}/billing")
    end

    it "falls back to FRONT_END_URL when Origin is not on the allowlist" do
      ENV["FRONT_END_URL"] = "https://app.speakanyway.com"

      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://example/cs")
      end

      post "/api/stripe/checkout_sessions/topup",
           params: { pack_key: "small" },
           headers: auth_headers(user).merge("HTTP_ORIGIN" => "https://evil.example.com")

      expect(captured[:success_url]).to start_with("https://app.speakanyway.com/billing/success")
      expect(captured[:cancel_url]).to eq("https://app.speakanyway.com/billing")
    ensure
      ENV.delete("FRONT_END_URL")
    end

    it "falls back to localhost when no Origin and no FRONT_END_URL" do
      ENV.delete("FRONT_END_URL")

      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://example/cs")
      end

      post "/api/stripe/checkout_sessions/topup",
           params: { pack_key: "small" },
           headers: auth_headers(user)

      expect(captured[:success_url]).to start_with("http://localhost:8100/billing/success?session_id={CHECKOUT_SESSION_ID}&type=topup&credits=100")
    end

    it "ignores a malformed Origin header" do
      ENV["FRONT_END_URL"] = "https://app.speakanyway.com"

      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://example/cs")
      end

      post "/api/stripe/checkout_sessions/topup",
           params: { pack_key: "small" },
           headers: auth_headers(user).merge("HTTP_ORIGIN" => "not a url at all")

      expect(captured[:success_url]).to start_with("https://app.speakanyway.com/billing/success")
    ensure
      ENV.delete("FRONT_END_URL")
    end
  end

  describe "success_url query string" do
    before { user.update!(stripe_customer_id: "cus_qs") }

    it "encodes the total credit_amount (pack credits * quantity)" do
      captured = nil
      allow(Stripe::Checkout::Session).to receive(:create) do |params|
        captured = params
        OpenStruct.new(url: "https://example/cs")
      end

      post "/api/stripe/checkout_sessions/topup",
           params: { pack_key: "medium", quantity: 2 },
           headers: auth_headers(user)

      # medium pack = 500 credits * 2 = 1000
      expect(captured[:success_url]).to include("type=topup")
      expect(captured[:success_url]).to include("credits=1000")
      expect(captured[:success_url]).to include("session_id={CHECKOUT_SESSION_ID}")
    end
  end
end
