require "rails_helper"

# customer.created handling. The email-match guard matters for email_signup:
# the webhook can race the stripe_customer_id save, and a re-invite! on the
# existing pending-invite user would rotate invitation_token — invalidating
# the magic link just emailed.
RSpec.describe "POST /api/webhooks (customer.created)", type: :request do
  include StripeHelpers

  before { ENV["STRIPE_WEBHOOK_SECRET"] ||= "whsec_test_dummy" }

  def stub_event(object, type:, event_id: "evt_#{SecureRandom.hex(4)}")
    event = OpenStruct.new(id: event_id, type: type, data: OpenStruct.new(object: object))
    allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
    event
  end

  context "when a user with that email already exists (id not yet persisted)" do
    it "does not re-invite or rotate their invitation token" do
      user = User.invite!(email: "racer@example.com", skip_invitation: true)
      original_token = user.invitation_token
      expect(original_token).to be_present

      stub_event(OpenStruct.new(id: "cus_race", email: "racer@example.com"), type: "customer.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(user.reload.invitation_token).to eq(original_token)
    end
  end

  context "when no user matches by customer id or email" do
    it "invites a new passwordless user" do
      stub_event(OpenStruct.new(id: "cus_fresh", email: "fresh@example.com"), type: "customer.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change(User, :count).by(1)

      user = User.find_by(email: "fresh@example.com")
      expect(user.invitation_token).to be_present
      expect(user.invitation_accepted_at).to be_nil
    end
  end
end
