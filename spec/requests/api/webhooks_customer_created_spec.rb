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

  context "when a user with that email already exists (stripe_customer_id not yet saved)" do
    it "does not re-invite or rotate their invitation token, and links the customer id" do
      user = User.invite!(email: "racer@example.com", skip_invitation: true)
      original_token = user.invitation_token
      expect(original_token).to be_present
      expect(user.stripe_customer_id).to be_blank

      stub_event(OpenStruct.new(id: "cus_race", email: "racer@example.com"), type: "customer.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.invitation_token).to eq(original_token)
      expect(user.stripe_customer_id).to eq("cus_race") # webhook self-heals the link
    end

    it "does not repoint a user who already has a different stripe_customer_id" do
      user = create(:user, email: "linked@example.com", stripe_customer_id: "cus_existing")
      stub_event(OpenStruct.new(id: "cus_new", email: "linked@example.com"), type: "customer.created")

      post_webhook("{}", header_with_signature)

      expect(user.reload.stripe_customer_id).to eq("cus_existing")
    end
  end

  context "when no user matches by customer id or email" do
    it "invites a new passwordless user and links the customer id" do
      stub_event(OpenStruct.new(id: "cus_fresh", email: "fresh@example.com"), type: "customer.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.to change(User, :count).by(1)

      user = User.find_by(email: "fresh@example.com")
      expect(user.invitation_token).to be_present
      expect(user.invitation_accepted_at).to be_nil
      expect(user.stripe_customer_id).to eq("cus_fresh")
    end
  end

  context "when inviting races a concurrent delivery (unique violation)" do
    it "re-finds the existing user instead of raising or duplicating" do
      existing = User.invite!(email: "dupe@example.com", skip_invitation: true)
      # Force the invite! branch (email lookup returns nil first), then have the
      # DB unique index reject the duplicate insert; handler must recover.
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with(email: "dupe@example.com").and_return(nil, existing)
      allow(User).to receive(:invite!).and_raise(ActiveRecord::RecordNotUnique.new("dup"))

      stub_event(OpenStruct.new(id: "cus_dupe", email: "dupe@example.com"), type: "customer.created")

      expect {
        post_webhook("{}", header_with_signature)
      }.not_to change(User, :count)
      expect(response).to have_http_status(:ok)
    end
  end
end
