require "rails_helper"

RSpec.describe "Signup admin notification", type: :request do
  include ActiveJob::TestHelper

  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_test_123")
  end

  # The standard signup route is POST /api/v1/users (api/v1/auths#sign_up).
  describe "POST /api/v1/users" do
    let(:params) do
      {
        email: "newsignup@example.com",
        password: "password123",
        password_confirmation: "password123",
        name: "New Signup",
        platform: "ios",
      }
    end

    it "records the signup context" do
      post "/api/v1/users", params: params
      user = User.find_by(email: "newsignup@example.com")
      expect(user.settings["signup_platform"]).to eq("ios")
      expect(user.settings["signup_method"]).to eq("standard")
    end

    it "enqueues exactly one admin new-user email" do
      expect {
        post "/api/v1/users", params: params
      }.to have_enqueued_mail(AdminMailer, :new_user_email).once
    end

    it "defaults the platform to web when the client sends none" do
      post "/api/v1/users", params: params.except(:platform)
      expect(User.find_by(email: "newsignup@example.com").settings["signup_platform"]).to eq("web")
    end
  end

  describe "POST /api/v1/users/email_signup" do
    it "records the email_only method and enqueues one admin email" do
      expect {
        post "/api/v1/users/email_signup", params: { email: "paidintent@example.com", platform: "web" }
      }.to have_enqueued_mail(AdminMailer, :new_user_email).once
      user = User.find_by(email: "paidintent@example.com")
      expect(user.settings["signup_method"]).to eq("email_only")
      expect(user.settings["signup_platform"]).to eq("web")
    end
  end
end
