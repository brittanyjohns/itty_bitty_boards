require "rails_helper"

# A 5-Year licensee has a paid plan_type but NO Stripe subscription
# (stripe_subscription_id: nil). Billing/subscription endpoints must not 500 on
# that state.
RSpec.describe "Licensee billing endpoints with nil stripe_subscription_id", type: :request do
  let(:user) do
    FactoryBot.create(:user, plan_type: "pro_5yr", stripe_customer_id: "cus_licensee").tap do |u|
      u.update_columns(stripe_subscription_id: nil, plan_expires_at: 5.years.from_now)
    end
  end

  it "GET /api/subscriptions returns 200 (no subscription to list)" do
    allow(Stripe::Subscription).to receive(:list).and_return(OpenStruct.new(data: []))

    get "/api/subscriptions", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["stripe_customer_id"]).to eq("cus_licensee")
  end
end
