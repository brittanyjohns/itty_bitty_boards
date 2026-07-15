require "rails_helper"

# The Stripe subscription webhook re-derives Pro-only extra-communicator add-on
# slots from the LIVE subscription items, so add / remove / downgrade self-heals.
RSpec.describe "POST /api/webhooks (extra communicator add-on)", type: :request do
  include StripeHelpers

  let(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_extra_comm",
      plan_type: "pro",
      plan_status: "active")
  end

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    ENV["STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY"] = "price_extra_m"
  end

  after { ENV.delete("STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY") }

  def build_metadata(hash)
    Class.new do
      def initialize(h) = (@h = h.transform_keys(&:to_s))
      def [](k) = @h[k.to_s]
      def presence = @h.presence
      def to_h = @h
    end.new(hash)
  end

  def price(plan_type: nil, id: "price_plan", kind: nil)
    meta = {}
    meta["plan_type"] = plan_type if plan_type
    meta["kind"] = kind if kind
    OpenStruct.new(id: id, metadata: build_metadata(meta), recurring: OpenStruct.new(interval: "month"))
  end

  def item(price_obj, quantity: 1)
    OpenStruct.new(price: price_obj, quantity: quantity)
  end

  def build_subscription(items:, status: "active")
    OpenStruct.new(
      id: "sub_#{SecureRandom.hex(3)}",
      customer: user.stripe_customer_id,
      status: status,
      current_period_end: 30.days.from_now.to_i,
      trial_end: nil,
      items: OpenStruct.new(data: items),
    )
  end

  def stub_event(object, type: "customer.subscription.updated")
    event = OpenStruct.new(id: "evt_#{SecureRandom.hex(4)}", type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  it "derives the add-on quantity from the subscription and keeps the plan price" do
    sub = build_subscription(items: [
      item(price(plan_type: "pro", id: "price_pro")),
      item(price(id: "price_extra_m", kind: "extra_communicator"), quantity: 2),
    ])
    stub_event(sub)

    post_webhook("{}", header_with_signature)

    user.reload
    expect(user.plan_type).to eq("pro")           # add-on item didn't hijack the plan price
    expect(user.extra_communicator_slots).to eq(2)
    expect(Permissions::CommunicatorLimits.slot_limit_for(user.settings)).to eq(7)
  end

  it "clears the add-on when a Pro user downgrades to Basic" do
    user.apply_extra_communicator_slots!(3)
    expect(user.reload.extra_communicator_slots).to eq(3)

    sub = build_subscription(items: [item(price(plan_type: "basic", id: "price_basic"))])
    stub_event(sub)

    post_webhook("{}", header_with_signature)

    user.reload
    expect(user.plan_type).to eq("basic")
    expect(user.extra_communicator_slots).to eq(0)
  end

  it "resets extras to 0 when the add-on item is removed but the user stays on Pro" do
    user.apply_extra_communicator_slots!(4)

    sub = build_subscription(items: [item(price(plan_type: "pro", id: "price_pro"))])
    stub_event(sub)

    post_webhook("{}", header_with_signature)

    expect(user.reload.extra_communicator_slots).to eq(0)
  end
end
