require "rails_helper"

# The customer.subscription.trial_will_end webhook should enqueue the
# Mailchimp trial-wrap journey (#291, journey #5) alongside the existing
# analytics event. Mirrors the stubbing pattern in webhooks_analytics_spec.
RSpec.describe "POST /api/webhooks (trial_wrap enqueue)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user, stripe_customer_id: "cus_trialwrap", plan_type: "basic", plan_status: "trialing")
  end

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    MailchimpTrialWrapJob.clear
  end

  def stub_event(object, type:)
    event = OpenStruct.new(id: "evt_#{SecureRandom.hex(4)}", type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  it "enqueues MailchimpTrialWrapJob with the user id and trial_end epoch" do
    trial_end = 1_781_000_000 # fixed epoch
    sub = OpenStruct.new(
      id: "sub_123",
      customer: user.stripe_customer_id,
      status: "trialing",
      trial_end: trial_end,
    )
    stub_event(sub, type: "customer.subscription.trial_will_end")

    expect { post_webhook("{}", header_with_signature) }
      .to change(MailchimpTrialWrapJob.jobs, :size).by(1)

    expect(MailchimpTrialWrapJob.jobs.last["args"]).to eq([user.id, trial_end])
  end
end
