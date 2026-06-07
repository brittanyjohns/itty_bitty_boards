require "rails_helper"

# RevenueCat (Apple/Google IAP) subscription-lifecycle webhook. Reaches parity
# with the Stripe webhook: purchase/renewal grants plan credits, expiration
# downgrades to free, cancellation is analytics-only (still entitled until
# expiry), billing issue keeps access during the grace period.
RSpec.describe "POST /api/billing/webhooks (RevenueCat)", type: :request do
  let!(:user) { FactoryBot.create(:user, plan_type: "free") }

  before { reset_user_credits!(user) }

  describe "auth" do
    it "rejects a missing/wrong Authorization header with 401 and no state change" do
      expect {
        post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id),
                        headers: rc_auth_headers("nope"))
      }.not_to change { user.reload.plan_type }
      expect(response).to have_http_status(:unauthorized)
      expect(ProcessedWebhookEvent.count).to eq(0)
    end

    it "accepts the correct shared-secret header" do
      post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "INITIAL_PURCHASE" do
    it "activates the plan, grants the tier's credits, and fires subscription_started" do
      event = rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id,
                       entitlement_ids: ["pro"], product_id: "pro_monthly")
      exp_ms = event["event"]["expiration_at_ms"]

      expect {
        post_rc_webhook(event)
      }.to change { user.reload.plan_credits_balance }.from(0).to(CreditService.monthly_credits_for("pro"))

      expect(response).to have_http_status(:ok)
      expect(user.plan_type).to eq("pro")
      expect(user.plan_status).to eq("active")

      tx = user.credit_transactions.where(stripe_event_id: "rc_#{event["event"]["id"]}").first
      expect(tx).to be_present
      expect(tx.kind).to eq("plan_grant")
      expect(tx.expires_at).to be_within(60.seconds).of(Time.at(exp_ms / 1000.0))

      expect(AnalyticsEvent.where(event_type: "subscription_started", user_id: user.id).count).to eq(1)
    end

    it "is idempotent: a replayed event id grants once and records one event row" do
      event = rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id, id: "rc_evt_dupe")

      expect {
        post_rc_webhook(event)
        post_rc_webhook(event)
      }.to change { user.reload.plan_credits_balance }.from(0).to(CreditService.monthly_credits_for("pro"))

      expect(ProcessedWebhookEvent.where(provider: "revenuecat", event_id: "rc_evt_dupe").count).to eq(1)
      expect(JSON.parse(response.body)["status"]).to eq("already_processed")
    end
  end

  describe "RENEWAL" do
    it "replaces leftover plan credits with a fresh grant (full reset, not additive)" do
      user.update!(plan_type: "pro", plan_status: "active")
      CreditService.grant_plan!(user, amount: 40, period_end: 1.day.ago)

      expect {
        post_rc_webhook(rc_event(type: "RENEWAL", app_user_id: user.id, entitlement_ids: ["pro"]))
      }.to change { user.reload.plan_credits_balance }.to(CreditService.monthly_credits_for("pro"))

      expect(user.credit_transactions.where(kind: "expire").count).to eq(1)
    end
  end

  describe "PRODUCT_CHANGE" do
    it "moves the user to the new tier and re-grants for it" do
      user.update!(plan_type: "basic", plan_status: "active")

      post_rc_webhook(rc_event(type: "PRODUCT_CHANGE", app_user_id: user.id,
                               entitlement_ids: ["pro"], product_id: "pro_monthly"))

      expect(user.reload.plan_type).to eq("pro")
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("pro"))
    end
  end

  describe "CANCELLATION" do
    it "does NOT downgrade (still entitled until expiry) and records the analytics event" do
      user.update!(plan_type: "pro", plan_status: "active")

      expect {
        post_rc_webhook(rc_event(type: "CANCELLATION", app_user_id: user.id, cancel_reason: "UNSUBSCRIBE"))
      }.not_to change { user.reload.plan_type }

      expect(user.plan_type).to eq("pro")
      expect(user).to be_paid_plan
      expect(AnalyticsEvent.where(event_type: "subscription_canceled", user_id: user.id).count).to eq(1)
    end
  end

  describe "EXPIRATION" do
    it "downgrades to free, snapshots the prior plan, and grants the free allowance" do
      user.update!(plan_type: "pro", plan_status: "active")

      post_rc_webhook(rc_event(type: "EXPIRATION", app_user_id: user.id))

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.paid_plan_type).to eq("pro")
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
    end
  end

  describe "BILLING_ISSUE" do
    it "keeps the plan and marks status past_due (grace period)" do
      user.update!(plan_type: "pro", plan_status: "active")

      post_rc_webhook(rc_event(type: "BILLING_ISSUE", app_user_id: user.id))

      user.reload
      expect(user.plan_type).to eq("pro")
      expect(user.plan_status).to eq("past_due")
    end
  end

  describe "SUBSCRIPTION_PAUSED" do
    it "applies free limits and marks status paused" do
      user.update!(plan_type: "pro", plan_status: "active")

      post_rc_webhook(rc_event(type: "SUBSCRIPTION_PAUSED", app_user_id: user.id))

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.plan_status).to eq("paused")
    end
  end

  describe "UNCANCELLATION" do
    it "sets status back to active without touching credits" do
      user.update!(plan_type: "pro", plan_status: "canceled")
      CreditService.grant_plan!(user, amount: 999, period_end: 30.days.from_now)

      expect {
        post_rc_webhook(rc_event(type: "UNCANCELLATION", app_user_id: user.id))
      }.not_to change { user.reload.plan_credits_balance }

      expect(user.plan_status).to eq("active")
    end
  end

  describe "sandbox gating" do
    it "ignores SANDBOX events when running as real production" do
      allow_any_instance_of(RevenueCat::WebhookProcessor).to receive(:production_live?).and_return(true)

      expect {
        post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id, environment: "SANDBOX"))
      }.not_to change { user.reload.plan_type }

      expect(JSON.parse(response.body)["status"]).to eq("ignored_sandbox")
    end

    it "honors SANDBOX events outside production (dev/test/staging)" do
      post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id, environment: "SANDBOX"))
      expect(user.reload.plan_type).to eq("pro")
    end
  end

  describe "edge cases" do
    it "returns 200 no_user_found for a numeric id with no matching user, still recording the event" do
      post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: 999_999, id: "rc_evt_nouser"))

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("no_user_found")
      expect(ProcessedWebhookEvent.where(event_id: "rc_evt_nouser").count).to eq(1)
    end

    it "skips anonymous RevenueCat ids" do
      post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: "$RCAnonymousID:abc123"))
      expect(JSON.parse(response.body)["status"]).to eq("no_user_found")
    end

    it "skips admins" do
      user.update!(role: "admin")
      expect {
        post_rc_webhook(rc_event(type: "INITIAL_PURCHASE", app_user_id: user.id))
      }.not_to change { user.reload.plan_credits_balance }
      expect(JSON.parse(response.body)["status"]).to eq("admin_skipped")
    end
  end
end
