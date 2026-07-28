require "rails_helper"

# Attribution for the ungated partner signup link (/sign-up/partner?ref=...).
# The ref is captured into settings["signup_ref"] and mirrored onto the
# user_signed_up PostHog event.
RSpec.describe "Signup ref attribution", type: :request do
  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_test_ref")
    allow(MailchimpEventJob).to receive(:perform_async)
    allow(PosthogService).to receive(:capture_for_user)
  end

  let(:params) do
    {
      email: "referred@example.com",
      password: "password123",
      password_confirmation: "password123",
      name: "Referred Signup",
    }
  end

  def referred_user
    User.find_by(email: "referred@example.com")
  end

  describe "POST /api/v1/users" do
    it "stores the ref" do
      post "/api/v1/users", params: params.merge(ref: "emilydiaz")

      expect(response).to have_http_status(:ok)
      expect(referred_user.settings["signup_ref"]).to eq("emilydiaz")
    end

    it "normalizes case and surrounding whitespace" do
      post "/api/v1/users", params: params.merge(ref: "  EmilyDiaz ")

      expect(referred_user.settings["signup_ref"]).to eq("emilydiaz")
    end

    it "leaves the key absent when no ref is sent" do
      post "/api/v1/users", params: params

      expect(referred_user.settings).not_to have_key("signup_ref")
    end

    it "leaves the key absent for a whitespace-only ref" do
      post "/api/v1/users", params: params.merge(ref: "   ")

      expect(referred_user.settings).not_to have_key("signup_ref")
    end

    it "truncates an overlong ref" do
      post "/api/v1/users", params: params.merge(ref: "x" * 200)

      expect(referred_user.settings["signup_ref"]).to eq("x" * User::SIGNUP_REF_MAX_LENGTH)
    end

    it "sends the ref on the user_signed_up event" do
      post "/api/v1/users", params: params.merge(ref: "emilydiaz")

      expect(PosthogService).to have_received(:capture_for_user).with(
        referred_user, "user_signed_up",
        properties: hash_including(signup_ref: "emilydiaz")
      )
    end

    it "sends a nil ref on the event when none was given" do
      post "/api/v1/users", params: params

      expect(PosthogService).to have_received(:capture_for_user).with(
        referred_user, "user_signed_up",
        properties: hash_including(signup_ref: nil)
      )
    end

    context "with a partner_pro signup" do
      before do
        allow(MailchimpService).to receive(:new).and_return(
          instance_double(MailchimpService, record_new_subscriber: true)
        )
        allow_any_instance_of(User).to receive(:send_partner_welcome_email)
      end

      it "stores the ref without disturbing partner provisioning" do
        post "/api/v1/users", params: params.merge(plan_type: "partner_pro", ref: "emilydiaz")

        expect(response).to have_http_status(:ok)
        user = referred_user
        expect(user.settings["signup_ref"]).to eq("emilydiaz")
        expect(user.role).to eq("partner")
        expect(user.plan_type).to eq("partner_pro")
        expect(user.plan_status).to eq("active")
        expect(user.paid_plan?).to be(true)
      end
    end
  end

  describe "POST /api/v1/users/email_signup" do
    it "stores the ref" do
      post "/api/v1/users/email_signup", params: { email: "referred@example.com", ref: "EmilyDiaz" }

      expect(response).to have_http_status(:ok)
      expect(referred_user.settings["signup_ref"]).to eq("emilydiaz")
    end

    it "leaves the key absent when no ref is sent" do
      post "/api/v1/users/email_signup", params: { email: "referred@example.com" }

      expect(referred_user.settings).not_to have_key("signup_ref")
    end
  end

  describe "admin_api_view" do
    it "exposes the ref at the top level" do
      user = create(:user)
      user.record_signup_context!(platform: "web", method: "standard", ref: "emilydiaz")

      expect(user.admin_api_view["signup_ref"]).to eq("emilydiaz")
    end

    it "is nil when the user has no ref" do
      expect(create(:user).admin_api_view["signup_ref"]).to be_nil
    end
  end
end
