require "rails_helper"

# POST /api/subscriptions/communicator_addon — set the Pro extra-communicator
# add-on to an exact quantity on the user's active subscription.
RSpec.describe "POST /api/subscriptions/communicator_addon", type: :request do
  let(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_addon",
      plan_type: "pro",
      plan_status: "active")
  end

  before { ENV["STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY"] = "price_extra_m" }
  after { ENV.delete("STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY") }

  def plan_item
    OpenStruct.new(id: "si_plan", quantity: 1,
      price: OpenStruct.new(id: "price_pro", metadata: { "plan_type" => "pro" }, recurring: OpenStruct.new(interval: "month")))
  end

  def addon_item(quantity: 1)
    OpenStruct.new(id: "si_addon", quantity: quantity,
      price: OpenStruct.new(id: "price_extra_m", metadata: { "kind" => "extra_communicator" }, recurring: OpenStruct.new(interval: "month")))
  end

  def stub_subscription(items:)
    sub = OpenStruct.new(id: "sub_addon", status: "active", items: OpenStruct.new(data: items))
    allow(Stripe::Subscription).to receive(:list).and_return(OpenStruct.new(data: [sub]))
    sub
  end

  it "403s for a non-Pro user" do
    user.update!(plan_type: "basic")
    post "/api/subscriptions/communicator_addon", params: { quantity: 2 }, headers: auth_headers(user)
    expect(response).to have_http_status(:forbidden)
  end

  it "422s when there is no active subscription" do
    allow(Stripe::Subscription).to receive(:list).and_return(OpenStruct.new(data: []))
    post "/api/subscriptions/communicator_addon", params: { quantity: 2 }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "adds a new add-on item and applies the slots when none exists" do
    stub_subscription(items: [plan_item])
    expect(Stripe::Subscription).to receive(:update)
      .with("sub_addon", { items: [{ price: "price_extra_m", quantity: 2 }] })
      .and_return(OpenStruct.new(id: "sub_addon"))

    post "/api/subscriptions/communicator_addon", params: { quantity: 2 }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["quantity"]).to eq(2)
    expect(body["communicator_slot_limit"]).to eq(7) # base 5 + 2
    expect(user.reload.extra_communicator_slots).to eq(2)
  end

  it "updates the existing add-on item's quantity" do
    stub_subscription(items: [plan_item, addon_item(quantity: 1)])
    expect(Stripe::SubscriptionItem).to receive(:update)
      .with("si_addon", { quantity: 4 })
      .and_return(OpenStruct.new(id: "si_addon"))

    post "/api/subscriptions/communicator_addon", params: { quantity: 4 }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(user.reload.extra_communicator_slots).to eq(4)
  end

  it "removes the add-on item and clears the slots when quantity is 0" do
    user.apply_extra_communicator_slots!(3)
    stub_subscription(items: [plan_item, addon_item(quantity: 3)])
    expect(Stripe::SubscriptionItem).to receive(:delete).with("si_addon").and_return(true)

    post "/api/subscriptions/communicator_addon", params: { quantity: 0 }, headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(user.reload.extra_communicator_slots).to eq(0)
  end
end
