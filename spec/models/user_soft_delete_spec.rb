require "rails_helper"

RSpec.describe "User soft-delete cleanup integration", type: :model do
  let(:user) { FactoryBot.create(:user, email: "test@example.com", plan_type: "basic") }

  before do
    allow(Stripe::Subscription).to receive(:retrieve).and_return(double(id: "sub_123"))
    allow(Stripe::Subscription).to receive(:cancel)
    allow(Stripe::PaymentMethod).to receive(:list).and_return(double(data: []))
    allow(Stripe::Customer).to receive(:update)
  end

  describe "#soft_delete_account! (Stripe path)" do
    before { user.update_columns(stripe_customer_id: "cus_123", stripe_subscription_id: "sub_123") }

    it "enqueues AccountDeletionCleanupJob with the original email before anonymization" do
      expect(AccountDeletionCleanupJob).to receive(:perform_async).with(
        user.id,
        "test@example.com",
        "user_requested",
      )

      user.soft_delete_account!(reason: "user_requested", actor_id: user.id)
    end

    it "records an account_deleted AnalyticsEvent" do
      allow(AccountDeletionCleanupJob).to receive(:perform_async)

      expect {
        user.soft_delete_account!(reason: "user_requested", actor_id: user.id)
      }.to change { AnalyticsEvent.where(event_type: "account_deleted").count }.by(1)

      event = AnalyticsEvent.last
      expect(event.user_id).to eq(user.id)
      expect(event.metadata["reason"]).to eq("user_requested")
    end
  end

  describe "#soft_delete_account! (non-Stripe path)" do
    it "enqueues AccountDeletionCleanupJob for users without a Stripe customer" do
      expect(AccountDeletionCleanupJob).to receive(:perform_async).with(
        user.id,
        "test@example.com",
        "user_requested",
      )

      user.soft_delete_account!(reason: "user_requested", actor_id: user.id)
    end

    it "records an account_deleted AnalyticsEvent" do
      allow(AccountDeletionCleanupJob).to receive(:perform_async)

      expect {
        user.soft_delete_account!(reason: "user_requested", actor_id: user.id)
      }.to change { AnalyticsEvent.where(event_type: "account_deleted").count }.by(1)
    end
  end
end
