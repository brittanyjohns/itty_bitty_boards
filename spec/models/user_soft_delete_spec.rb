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

  # Regression guard for a production-only break: anonymization assigned
  # users.child_lookup_key unconditionally. That column is declared in
  # schema.rb (so dev/CI, which build from schema.rb, have it and every test
  # passed) but is ABSENT in production, because the migration that adds it
  # gained those lines after it had already run there. Result: NoMethodError
  # on every account deletion in prod — including the user-facing endpoint —
  # while the suite stayed green. Simulating the column's absence is the only
  # way a test can see this.
  describe "when users.child_lookup_key does not exist (production's shape)" do
    # BOTH stubs are required. Faking has_attribute? alone proves nothing:
    # the unguarded assignment would still call a setter that really exists in
    # the test schema and pass. The setter has to be absent too, exactly as it
    # is in production.
    before do
      allow(AccountDeletionCleanupJob).to receive(:perform_async)
      allow(user).to receive(:has_attribute?).and_call_original
      allow(user).to receive(:has_attribute?).with(:child_lookup_key).and_return(false)
      allow(user).to receive(:child_lookup_key=)
        .and_raise(NoMethodError.new("undefined method `child_lookup_key=' for an instance of User"))
    end

    it "soft-deletes without raising" do
      expect { user.soft_delete_account!(reason: "user_requested", actor_id: user.id) }
        .not_to raise_error
    end

    it "still anonymizes and marks the account deleted" do
      user.soft_delete_account!(reason: "user_requested", actor_id: user.id)
      user.reload

      expect(user.deleted_at).to be_present
      expect(user.email).not_to eq("test@example.com")
      expect(user.name).to eq("Deleted User")
    end
  end

  describe "when the column does exist" do
    it "still clears it, so an identifying key isn't left behind" do
      allow(AccountDeletionCleanupJob).to receive(:perform_async)
      skip "column absent in this environment too" unless User.column_names.include?("child_lookup_key")
      user.update_column(:child_lookup_key, "lookup-abc")

      user.soft_delete_account!(reason: "user_requested", actor_id: user.id)

      expect(user.reload.child_lookup_key).to be_nil
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
