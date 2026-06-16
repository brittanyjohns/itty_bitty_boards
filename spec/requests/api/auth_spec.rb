require "rails_helper"

RSpec.describe "API::V1::Auth", type: :request do
  let!(:user) { create(:user, email: "test@example.com", password: "password123") }

  describe "POST /api/v1/login" do
    context "with valid credentials" do
      it "returns 200 and an authentication token" do
        post "/api/v1/login", params: { email: user.email, password: "password123" }
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["token"]).to eq(user.authentication_token)
        expect(body["user"]).to be_present
      end
    end

    context "with invalid password" do
      it "returns 401" do
        post "/api/v1/login", params: { email: user.email, password: "wrongpassword" }
        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)).to have_key("error")
      end
    end

    context "with non-existent email" do
      it "returns 401" do
        post "/api/v1/login", params: { email: "nobody@example.com", password: "password123" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # Regression: this route used to point at the non-existent auths#sign_in
  # action, so every request raised ActionNotFound. It now routes to
  # auths#create, same as /api/v1/login.
  describe "POST /api/v1/users/sign_in" do
    it "signs in with valid credentials" do
      post "/api/v1/users/sign_in", params: { email: user.email, password: "password123" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["token"]).to eq(user.authentication_token)
      expect(body["user"]).to be_present
    end

    it "returns 401 with invalid credentials" do
      post "/api/v1/users/sign_in", params: { email: user.email, password: "wrongpassword" }
      expect(response).to have_http_status(:unauthorized)
    end

    context "when the user is stranded in paid/unpaid limbo (missed downgrade webhook)" do
      let!(:stranded) do
        create(:user, email: "stranded@example.com", password: "password123",
          plan_type: "basic", plan_status: "paused",
          stripe_subscription_id: "sub_stranded", plan_credits_balance: 0)
      end

      it "self-heals to Free with credits at sign-in, without a Stripe call" do
        post "/api/v1/users/sign_in", params: { email: stranded.email, password: "password123" }

        expect(response).to have_http_status(:ok)
        stranded.reload
        expect(stranded.plan_type).to eq("free")
        expect(stranded.paid_plan_type).to eq("basic")
        expect(stranded.stripe_subscription_id).to be_nil
        expect(stranded.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))
      end
    end

    it "leaves a healthy paid user untouched at sign-in" do
      paid = create(:user, email: "paid@example.com", password: "password123",
        plan_type: "basic", plan_status: "active", stripe_subscription_id: "sub_active")

      post "/api/v1/users/sign_in", params: { email: paid.email, password: "password123" }

      expect(response).to have_http_status(:ok)
      paid.reload
      expect(paid.plan_type).to eq("basic")
      expect(paid.stripe_subscription_id).to eq("sub_active")
    end
  end

  describe "POST /api/v1/forgot_password" do
    context "when the email belongs to a registered user" do
      it "returns 200" do
        post "/api/v1/forgot_password", params: { email: user.email }
        expect(response).to have_http_status(:ok)
      end
    end

    context "when the email is not registered" do
      # Security: should return 200 to prevent account enumeration.
      # Currently returns 404 — this test will fail until the fix is applied.
      it "returns 200 (not 404, to prevent email enumeration)" do
        post "/api/v1/forgot_password", params: { email: "nobody@example.com" }
        expect(response).to have_http_status(:ok)
      end

      it "returns the same response body as a valid email" do
        post "/api/v1/forgot_password", params: { email: user.email }
        valid_message = JSON.parse(response.body)["message"]

        post "/api/v1/forgot_password", params: { email: "nobody@example.com" }
        invalid_body = JSON.parse(response.body)

        expect(invalid_body["message"]).to eq(valid_message)
        expect(invalid_body).not_to have_key("error")
      end
    end
  end

  describe "POST /api/v1/reset_password" do
    before do
      post "/api/v1/forgot_password", params: { email: user.email }
      user.reload
    end

    context "with a valid reset token" do
      it "resets the password and returns 200" do
        post "/api/v1/reset_password", params: {
          reset_password_token: user.reset_password_token,
          password: "newpassword123",
          password_confirmation: "newpassword123",
        }
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["message"]).to be_present
      end
    end

    context "with an invalid token" do
      it "returns a non-200 status" do
        post "/api/v1/reset_password", params: {
          reset_password_token: "invalidtoken",
          password: "newpassword123",
          password_confirmation: "newpassword123",
        }
        expect(response).not_to have_http_status(:ok)
      end
    end
  end

  describe "POST /api/v1/users (sign_up)" do
    let(:valid_params) do
      {
        email: "new-free@example.com",
        password: "password123",
        password_confirmation: "password123",
        name: "New Free",
      }
    end

    before do
      allow(User).to receive(:create_stripe_customer).and_return("cus_test")
      allow(MailchimpEventJob).to receive(:perform_async)
    end

    it "sends the free welcome email on a plain signup" do
      expect_any_instance_of(User).to receive(:send_welcome_email).with("free")

      post "/api/v1/users", params: valid_params

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["token"]).to be_present
    end

    it "does not send the free welcome email for partner_pro signups" do
      expect_any_instance_of(User).not_to receive(:send_welcome_email)
      expect_any_instance_of(User).to receive(:send_partner_welcome_email)
      allow(User).to receive(:handle_new_partner_pro_subscription)

      post "/api/v1/users", params: valid_params.merge(plan_type: "partner_pro")

      expect(response).to have_http_status(:ok)
    end

    it "skips the welcome email when should_send_welcome_email? is false" do
      allow_any_instance_of(User).to receive(:should_send_welcome_email?).and_return(false)
      expect_any_instance_of(User).not_to receive(:send_welcome_email)

      post "/api/v1/users", params: valid_params

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/users/current" do
    it "returns the current user when authenticated" do
      get "/api/v1/users/current", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["user"]).to be_present
    end

    it "returns 401 when not authenticated" do
      get "/api/v1/users/current"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
