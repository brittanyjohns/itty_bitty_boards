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

  # Fix A: nothing else recomputes has_payment_method during a quiet trial, so
  # trial_will_end (fired ~3 days before end, exactly when the frontend CTA
  # turns on) is the sole authoritative correction point. See
  # API::WebhooksController#handle_trial_will_end.
  describe "has_payment_method recompute" do
    def build_sub(default_payment_method: nil)
      OpenStruct.new(
        id: "sub_recompute",
        customer: user.stripe_customer_id,
        status: "trialing",
        trial_end: 1_781_000_000,
        default_payment_method: default_payment_method,
      )
    end

    it "recomputes the flag for a trialing user from the live subscription" do
      user.update!(settings: user.settings.merge("has_payment_method" => nil))
      stub_event(build_sub(default_payment_method: "pm_card_123"), type: "customer.subscription.trial_will_end")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
      expect(user.reload.settings["has_payment_method"]).to eq(true)
    end

    it "does not write has_payment_method for a non-trialing user" do
      user.update!(plan_status: "active", settings: user.settings.merge("has_payment_method" => true))
      expect(Stripe::Customer).not_to receive(:retrieve)
      stub_event(build_sub, type: "customer.subscription.trial_will_end")

      post_webhook("{}", header_with_signature)

      expect(response).to have_http_status(:ok)
      expect(user.reload.settings["has_payment_method"]).to eq(true)
    end

    it "still fires analytics and enqueues the Mailchimp job when the Stripe recompute fails" do
      user.update!(settings: user.settings.merge("has_payment_method" => false))
      allow(Stripe::Customer).to receive(:retrieve).and_raise(Stripe::APIError.new("boom"))
      trial_end = 1_781_000_000
      stub_event(build_sub, type: "customer.subscription.trial_will_end")

      expect {
        expect { post_webhook("{}", header_with_signature) }
          .to change(MailchimpTrialWrapJob.jobs, :size).by(1)
      }.to change { AnalyticsEvent.for_event("trial_will_end").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(MailchimpTrialWrapJob.jobs.last["args"]).to eq([user.id, trial_end])
      # The flag itself is untouched by the failed recompute (previous value kept).
      expect(user.reload.settings["has_payment_method"]).to eq(false)
    end
  end
end
