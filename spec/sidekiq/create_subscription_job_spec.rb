require "rails_helper"

# CreateSubscriptionJob references Subscription.build_from_stripe_event,
# which doesn't exist on the Subscription model. The job is currently
# unreachable (no enqueue sites in app/) and swallows all errors internally.
# These specs pin that "doesn't crash the worker" behavior so a future
# implementer doesn't silently re-enable it without noticing the missing
# method.
RSpec.describe CreateSubscriptionJob, type: :job do
  describe "#perform" do
    it "swallows errors from invalid JSON payloads (no worker crash)" do
      expect {
        described_class.new.perform("not-valid-json")
      }.not_to raise_error
    end

    it "swallows errors from the missing Subscription.build_from_stripe_event" do
      payload = { "id" => "sub_test", "customer" => "cus_test" }.to_json
      expect {
        described_class.new.perform(payload, nil)
      }.not_to raise_error
    end
  end
end
