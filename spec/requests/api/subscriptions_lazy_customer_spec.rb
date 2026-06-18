require "rails_helper"

# Free/legacy/mobile accounts may not have a Stripe customer yet (e.g. a user
# created outside the normal signup UI). The subscription read/list endpoints
# must create one lazily rather than passing a nil customer to Stripe (which
# 500s). See API::SubscriptionsController.
RSpec.describe "API::SubscriptionsController lazy Stripe customer", type: :request do
  let(:empty_list) { OpenStruct.new(data: [], has_more: false) }

  describe "GET /api/subscriptions" do
    context "when the user has no Stripe customer" do
      let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

      it "lazily creates one, persists it, and lists subscriptions" do
        expect(User).to receive(:create_stripe_customer).with(user.email).once.and_return("cus_lazy")
        captured = nil
        expect(Stripe::Subscription).to receive(:list) do |params|
          captured = params
          empty_list
        end

        get "/api/subscriptions", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(user.reload.stripe_customer_id).to eq("cus_lazy")
        expect(captured[:customer]).to eq("cus_lazy")
        expect(JSON.parse(response.body)["stripe_customer_id"]).to eq("cus_lazy")
      end
    end

    context "when the user already has a Stripe customer" do
      let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

      it "does not create a new customer" do
        allow(User).to receive(:create_stripe_customer)
        allow(Stripe::Subscription).to receive(:list).and_return(empty_list)

        get "/api/subscriptions", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(User).not_to have_received(:create_stripe_customer)
      end
    end

    context "when Stripe raises" do
      let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

      it "returns 400, not 500" do
        allow(Stripe::Subscription).to receive(:list)
          .and_raise(Stripe::InvalidRequestError.new("boom", nil))

        get "/api/subscriptions", headers: auth_headers(user)

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["error"]).to eq("Failed to load subscriptions")
      end
    end
  end

  describe "GET /api/subscriptions/list" do
    context "when the user has no Stripe customer" do
      let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

      it "lazily creates one and returns an empty list" do
        expect(User).to receive(:create_stripe_customer).with(user.email).once.and_return("cus_lazy")
        captured = nil
        expect(Stripe::Subscription).to receive(:list) do |params|
          captured = params
          empty_list
        end

        get "/api/subscriptions/list", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(user.reload.stripe_customer_id).to eq("cus_lazy")
        expect(captured[:customer]).to eq("cus_lazy")
        expect(JSON.parse(response.body)["subscriptions"]).to eq([])
      end
    end
  end

  describe "POST /api/subscriptions/create_customer_session" do
    context "when the user has no Stripe customer" do
      let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

      it "lazily creates one before opening the session" do
        expect(User).to receive(:create_stripe_customer).with(user.email).once.and_return("cus_lazy")
        captured = nil
        expect(Stripe::CustomerSession).to receive(:create) do |params|
          captured = params
          OpenStruct.new(client_secret: "cs_secret")
        end

        post "/api/subscriptions/create_customer_session", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(user.reload.stripe_customer_id).to eq("cus_lazy")
        expect(captured[:customer]).to eq("cus_lazy")
      end
    end
  end

  describe "POST /api/subscriptions/add_item" do
    let(:user) { FactoryBot.create(:user, stripe_customer_id: nil) }

    it "ensures a customer and returns 422 when there's no subscription to modify" do
      expect(User).to receive(:create_stripe_customer).with(user.email).once.and_return("cus_lazy")
      allow(Stripe::Price).to receive(:list)
        .and_return(OpenStruct.new(data: [OpenStruct.new(id: "price_x")]))
      allow(Stripe::Subscription).to receive(:list)
        .and_return(OpenStruct.new("data" => []))

      post "/api/subscriptions/add_item",
        params: { lookup_key: "basic_extra_comm" }, headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("No active subscription to modify")
      expect(user.reload.stripe_customer_id).to eq("cus_lazy")
    end
  end
end
