require "rails_helper"

# Covers the plan-correct welcome email triggered from the Stripe subscription
# upsert webhook — the only path that delivers welcome_basic_email /
# welcome_pro_email to web subscribers. See API::WebhooksController#handle_subscription_upsert.
RSpec.describe "POST /api/webhooks (plan welcome email)", type: :request do
  include StripeHelpers

  let!(:user) do
    FactoryBot.create(:user,
      stripe_customer_id: "cus_plan_welcome",
      plan_type: "free",
      plan_status: nil,
      settings: { "receipt_email_sent" => true })
  end

  before do
    ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy"
    allow(AdminMailer).to receive(:new_user_email).and_return(double(deliver_later: true))
  end

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  def build_metadata(hash)
    Class.new do
      def initialize(h) @h = h.transform_keys(&:to_s) end
      def [](k) = @h[k.to_s]
      def presence; @h.presence; end
      def to_h; @h; end
    end.new(hash)
  end

  def build_price(plan_type: "basic", monthly_credits: 400, id: "price_basic")
    OpenStruct.new(id: id, metadata: build_metadata({ "plan_type" => plan_type, "monthly_credits" => monthly_credits.to_s }))
  end

  def build_subscription(status: "trialing", price: build_price, current_period_end: 14.days.from_now, trial_end: 14.days.from_now, customer: user.stripe_customer_id)
    OpenStruct.new(
      id: "sub_#{SecureRandom.hex(3)}",
      customer: customer,
      status: status,
      current_period_end: current_period_end.to_i,
      trial_end: trial_end&.to_i,
      items: OpenStruct.new(data: [OpenStruct.new(price: price, quantity: 1)]),
    )
  end

  describe "first transition into trialing" do
    it "sends the Basic plan welcome (not the Free one)" do
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:welcome_basic_email).and_return(mail)
      allow(UserMailer).to receive(:welcome_free_email).and_return(mail)

      sub = build_subscription(status: "trialing", price: build_price(plan_type: "basic"))
      stub_event(sub, type: "customer.subscription.created")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).to have_received(:welcome_basic_email).once
      expect(UserMailer).not_to have_received(:welcome_free_email)
      expect(user.reload.settings["plan_welcome_sent_for"]).to include("basic")
    end

    it "sends the Pro plan welcome for a pro trial" do
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:welcome_pro_email).and_return(mail)

      sub = build_subscription(status: "trialing", price: build_price(plan_type: "pro", monthly_credits: 1500, id: "price_pro"))
      stub_event(sub, type: "customer.subscription.created")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).to have_received(:welcome_pro_email).once
      expect(user.reload.settings["plan_welcome_sent_for"]).to include("pro")
    end
  end

  describe "re-fires of subscription.updated" do
    it "does NOT re-send the plan welcome when status stays trialing" do
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:welcome_basic_email).and_return(mail)

      sub = build_subscription(status: "trialing", price: build_price(plan_type: "basic"))
      stub_event(sub, type: "customer.subscription.created")
      post_webhook("{}", header_with_signature)

      sub2 = build_subscription(status: "trialing", price: build_price(plan_type: "basic"))
      stub_event(sub2, type: "customer.subscription.updated")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).to have_received(:welcome_basic_email).once
    end

    it "does NOT re-send when trialing→active for the same plan" do
      mail = double(deliver_later: true)
      allow(UserMailer).to receive(:welcome_basic_email).and_return(mail)

      sub = build_subscription(status: "trialing", price: build_price(plan_type: "basic"))
      stub_event(sub, type: "customer.subscription.created")
      post_webhook("{}", header_with_signature)

      sub2 = build_subscription(status: "active", price: build_price(plan_type: "basic"))
      stub_event(sub2, type: "customer.subscription.updated")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).to have_received(:welcome_basic_email).once
    end
  end

  describe "real plan change (basic → pro)" do
    it "sends the Pro welcome on upgrade after Basic was already sent" do
      user.update!(settings: user.settings.merge("plan_welcome_sent_for" => ["basic"]))
      basic_mail = double(deliver_later: true)
      pro_mail = double(deliver_later: true)
      allow(UserMailer).to receive(:welcome_basic_email).and_return(basic_mail)
      allow(UserMailer).to receive(:welcome_pro_email).and_return(pro_mail)

      sub = build_subscription(status: "active", price: build_price(plan_type: "pro", monthly_credits: 1500, id: "price_pro"))
      stub_event(sub, type: "customer.subscription.updated")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).to have_received(:welcome_pro_email).once
      expect(UserMailer).not_to have_received(:welcome_basic_email)
    end
  end

  describe "admin users" do
    it "does NOT send any welcome email for admins" do
      user.update!(role: "admin")
      allow(UserMailer).to receive(:welcome_basic_email)
      allow(UserMailer).to receive(:welcome_pro_email)
      allow(UserMailer).to receive(:welcome_free_email)

      sub = build_subscription(status: "trialing", price: build_price(plan_type: "basic"))
      stub_event(sub, type: "customer.subscription.created")
      post_webhook("{}", header_with_signature)

      expect(UserMailer).not_to have_received(:welcome_basic_email)
      expect(UserMailer).not_to have_received(:welcome_pro_email)
      expect(UserMailer).not_to have_received(:welcome_free_email)
    end
  end
end
