require "rails_helper"

RSpec.describe "PostHog auth events", type: :request do
  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_test")
    allow(MailchimpEventJob).to receive(:perform_async)
    allow(PosthogService).to receive(:capture_for_user)
  end

  describe "POST /api/v1/users (sign_up)" do
    let(:params) do
      { email: "new@example.com", password: "password123", password_confirmation: "password123" }
    end

    it "captures user_signed_up with signup_method standard" do
      post "/api/v1/users", params: params

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: "new@example.com")
      expect(PosthogService).to have_received(:capture_for_user).with(
        user, "user_signed_up",
        properties: hash_including(signup_method: "standard", platform: "web")
      )
    end

    it "captures the platform when provided" do
      post "/api/v1/users", params: params.merge(platform: "ios")

      user = User.find_by(email: "new@example.com")
      expect(PosthogService).to have_received(:capture_for_user).with(
        user, "user_signed_up",
        properties: hash_including(platform: "ios")
      )
    end

    it "does not capture when signup fails" do
      post "/api/v1/users", params: params.merge(password_confirmation: "mismatch")

      expect(response).to have_http_status(:unprocessable_content)
      expect(PosthogService).not_to have_received(:capture_for_user)
    end
  end

  describe "POST /api/v1/users/email_signup" do
    it "captures user_signed_up with signup_method email_only" do
      post "/api/v1/users/email_signup", params: { email: "buyer@example.com" }

      expect(response).to have_http_status(:ok)
      user = User.find_by(email: "buyer@example.com")
      expect(PosthogService).to have_received(:capture_for_user).with(
        user, "user_signed_up",
        properties: hash_including(signup_method: "email_only", platform: "web")
      )
    end

    it "does not capture for duplicate email" do
      create(:user, email: "taken@example.com")

      post "/api/v1/users/email_signup", params: { email: "taken@example.com" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(PosthogService).not_to have_received(:capture_for_user)
    end
  end

  describe "POST /api/v1/login (sign_in)" do
    let!(:user) { create(:user, email: "login@example.com", password: "password123") }

    it "captures user_signed_in on successful login" do
      post "/api/v1/login", params: { email: "login@example.com", password: "password123" }

      expect(response).to have_http_status(:ok)
      expect(PosthogService).to have_received(:capture_for_user).with(
        user, "user_signed_in",
        properties: hash_including(plan_type: user.plan_type)
      )
    end

    it "does not capture on failed login" do
      post "/api/v1/login", params: { email: "login@example.com", password: "wrong" }

      expect(response).to have_http_status(:unauthorized)
      expect(PosthogService).not_to have_received(:capture_for_user)
    end
  end
end
