require "rails_helper"

RSpec.describe "API::Webhooks", type: :request do
  WEBHOOK_PATH = "/api/webhooks"
  let(:secret) { "whsec_test_123" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return(secret)
  end

  context "with inner object fixtures (wrapped)" do
    it "handles customer.created" do
      post_webhook_from_object_fixture("customer_object", type: "customer.created", path: WEBHOOK_PATH, secret: secret)
      expect(response).to have_http_status(:ok)
    end

    it "handles checkout.session.completed" do
      post_webhook_from_object_fixture("checkout_session_object", type: "checkout.session.completed", path: WEBHOOK_PATH, secret: secret)
      expect(response).to have_http_status(:ok)
    end
  end

  it "returns 400 on bad signature" do
    raw = read_fixture("customer_object")
    post WEBHOOK_PATH,
         params: raw,
         headers: { "Stripe-Signature" => "t=#{Time.now.to_i},v1=bad", "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:bad_request)
  end
end
