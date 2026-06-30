require "rails_helper"

# The customer.subscription.updated webhook should enqueue the Mailchimp
# `subscription_started` Customer Journey on the non-active -> active
# transition (the paid-tier onboarding nurture), alongside the existing
# subscription_started analytics. Mirrors the stubbing pattern in
# webhooks_trial_wrap_spec.
RSpec.describe "POST /api/webhooks (subscription_started journey enqueue)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user, stripe_customer_id: "cus_substarted", plan_type: "basic", plan_status: "trialing")
  end

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    MailchimpEventJob.clear
  end

  def stub_event(object, type:, id: nil)
    event = OpenStruct.new(id: id || "evt_#{SecureRandom.hex(4)}", type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def active_subscription(status:)
    price = OpenStruct.new(
      id: "price_basic",
      metadata: { "plan_type" => "basic" },
      recurring: OpenStruct.new(interval: "month"),
    )
    OpenStruct.new(
      id: "sub_substarted",
      customer: user.stripe_customer_id,
      status: status,
      trial_end: nil,
      items: OpenStruct.new(data: [OpenStruct.new(price: price)]),
    )
  end

  it "enqueues the subscription_started journey on trialing -> active" do
    stub_event(active_subscription(status: "active"), type: "customer.subscription.updated")

    expect { post_webhook("{}", header_with_signature) }
      .to change(MailchimpEventJob.jobs, :size).by(1)

    args = MailchimpEventJob.jobs.last["args"]
    expect(args[0]).to eq(user.id)
    expect(args[1]).to eq("journey")
    expect(args[2]).to eq("journey_key" => "subscription_started")
  end

  it "does not re-enqueue when the user was already active (renewal)" do
    user.update!(plan_status: "active")
    stub_event(active_subscription(status: "active"), type: "customer.subscription.updated")

    expect { post_webhook("{}", header_with_signature) }
      .not_to change(MailchimpEventJob.jobs, :size)
  end
end
