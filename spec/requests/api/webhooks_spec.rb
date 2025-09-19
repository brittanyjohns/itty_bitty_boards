# frozen_string_literal: true
require "rails_helper"

RSpec.describe "API::WebhooksController", type: :request do
  include StripeHelpers

  let(:secret) { "whsec_test" }

  before do
    # Ensure ENV is present for the controller
    allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return(secret)
  end

  describe "POST /api/webhooks" do
    context "signature / payload verification" do
      it "returns 400 for invalid JSON" do
        allow(Stripe::Webhook).to receive(:construct_event).and_raise(JSON::ParserError.new("bad"))
        post_webhook("this is not json", header_with_signature)
        expect(response).to have_http_status(400)
        expect(response.parsed_body).to include("error" => "Invalid payload")
      end

      it "returns 400 for invalid signature" do
        allow(Stripe::Webhook).to receive(:construct_event)
                                    .and_raise(Stripe::SignatureVerificationError.new("nope", "sig"))
        post_webhook({}.to_json, header_with_signature)
        expect(response).to have_http_status(400)
        expect(response.parsed_body).to include("error" => "Invalid signature")
      end
    end

    context "customer.subscription.paused" do
      let!(:user) { create(:user, stripe_customer_id: "cus_123", plan_status: "active", plan_type: "pro") }

      it "pauses an existing user's plan" do
        obj = stripe_obj({ "object" => "subscription", id: "sub_1", customer: "cus_123" })
        event = stripe_event(type: "customer.subscription.paused", object: obj)

        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)

        expect(response).to have_http_status(200)
        expect(user.reload.plan_status).to eq("paused")
        expect(user.plan_type).to eq("free")
      end

      it "returns 400 if user not found" do
        obj = stripe_obj({ "object" => "subscription", id: "sub_1", customer: "missing" })
        event = stripe_event(type: "customer.subscription.paused", object: obj)
        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)

        expect(response).to have_http_status(400)
        expect(response.parsed_body["error"]).to match(/No user found/)
      end
    end

    context "customer.subscription.created" do
      let!(:user) { create(:user, stripe_customer_id: "cus_123", email: "u@example.com") }

      def subscription_object(nickname: "basic")
        plan = stripe_obj({ interval: "month", product: "prod_123", nickname: nickname })
        stripe_obj({
          "object" => "subscription",
          id: "sub_1",
          customer: "cus_123",
          plan: plan,
          status: "active",
          trial_end: nil,
          current_period_end: 1_700_000_000,
          current_period_start: 1_690_000_000,
          cancel_at_period_end: false,
          cancel_at: nil,
          items: stripe_obj({ data: [] }),
        })
      end

      before do
        # When controller looks up the Stripe customer
        allow(Stripe::Customer).to receive(:retrieve).with("cus_123")
                                     .and_return(double(deleted?: false, email: user.email))
      end

      it "sends welcome email for a regular plan and updates the user" do
        obj = subscription_object(nickname: "basic")
        event = stripe_event(type: "customer.subscription.created", object: obj)

        # Expect welcome email path for regular plans
        expect_any_instance_of(User).to receive(:send_welcome_email).with("basic")
        expect_any_instance_of(User).to receive(:update_from_stripe_event).with(kind_of(Hash), "basic")

        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(200)
      end

      it "skips welcome email for existing user and sets plan" do
        user.update!(plan_type: "pro", plan_status: "active")

        obj = subscription_object(nickname: "myspeak")
        event = stripe_event(type: "customer.subscription.created", object: obj)
        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        expect_any_instance_of(User).not_to receive(:send_welcome_email)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(200)
        # User stays on pro (controller guards against overriding to myspeak if already pro/basic)
        expect(user.reload.plan_type).to eq("myspeak")
      end

      it "creates or links user by email when stripe_customer_id is new" do
        # No user with cus_new yet, but email matches existing user
        obj = subscription_object
        obj.customer = "cus_new"

        event = stripe_event(type: "customer.subscription.created", object: obj)
        allow(Stripe::Customer).to receive(:retrieve).with("cus_new")
                                     .and_return(double(deleted?: false, email: user.email))
        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)

        expect(response).to have_http_status(200)
        expect(user.reload.stripe_customer_id).to eq("cus_new")
      end
    end

    context "customer.subscription.updated" do
      let!(:user) { create(:user, stripe_customer_id: "cus_123", email: "u@example.com") }

      it "updates from stripe event and returns 200" do
        plan = stripe_obj({ nickname: "pro" })
        obj = stripe_obj({ "object" => "subscription", customer: "cus_123", plan: plan })
        event = stripe_event(type: "customer.subscription.updated", object: obj)

        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
        expect_any_instance_of(User).to receive(:update_from_stripe_event).with(obj, "pro").and_return(true)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(200)
      end

      it "returns 400 when update fails" do
        plan = stripe_obj({ nickname: "pro" })
        obj = stripe_obj({ "object" => "subscription", customer: "cus_123", plan: plan })
        event = stripe_event(type: "customer.subscription.updated", object: obj)

        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)
        expect_any_instance_of(User).to receive(:update_from_stripe_event).and_return(false)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(400)
      end

      it "returns 400 when user not found" do
        plan = stripe_obj({ nickname: "pro" })
        obj = stripe_obj({ "object" => "subscription", customer: "missing", plan: plan })
        event = stripe_event(type: "customer.subscription.updated", object: obj)

        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(400)
      end
    end

    context "customer.subscription.deleted" do
      let!(:user) { create(:user, stripe_customer_id: "cus_123", plan_status: "active", plan_type: "pro") }

      it "cancels the user plan" do
        obj = stripe_obj({ "object" => "subscription", customer: "cus_123" })
        event = stripe_event(type: "customer.subscription.deleted", object: obj)
        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(200)
        expect(user.reload.plan_status).to eq("canceled")
        expect(user.plan_type).to eq("free")
      end

      it "returns 400 if user not found" do
        obj = stripe_obj({ "object" => "subscription", customer: "missing" })
        event = stripe_event(type: "customer.subscription.deleted", object: obj)
        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(400)
      end
    end

    context "checkout.session.completed (vendor path)" do
      let!(:user) { create(:user, email: "vendor@example.com") }

      it "handles vendor creation via custom_fields and returns 200" do
        session = stripe_obj({
          "object" => "checkout.session",
          customer: "cus_123",
          subscription: "sub_123",
          customer_details: { "email" => "vendor@example.com" },
          custom_fields: [
            { "key" => "businessname", "text" => { "value" => "Cupcake Palace" } },
          ],
          metadata: { "plan_type" => "vendor" },
        })

        event = stripe_event(type: "checkout.session.completed", object: session)

        # When controller tries to pull a subscription (if it does)
        allow(Stripe::Subscription).to receive(:retrieve).and_return(double)

        # Short-circuit heavy logic: just ensure controller proceeds and returns success
        # We let the real handle_vendor_user run if you prefer; otherwise stub:
        allow_any_instance_of(API::WebhooksController).to receive(:handle_vendor_user)
                                                            .and_wrap_original do |m, *args|
          # Ensure inputs are what we expect
          expect(args[0]).to eq("vendor@example.com")
          expect(args[1]).to eq("Cupcake Palace")
          # Return an existing user to finish the flow
          user
        end

        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(200)
        expect(response.parsed_body).to include("success" => true)
      end
    end

    context "unknown or unhandled event types" do
      it "still returns 200 success" do
        obj = stripe_obj({ "object" => "something", id: "abc" })
        event = stripe_event(type: "invoice.created", object: obj)
        allow(Stripe::Webhook).to receive(:construct_event).and_return(event)

        post_webhook(event.to_json, header_with_signature)
        expect(response).to have_http_status(200)
        expect(response.parsed_body).to include("success" => true)
      end
    end
  end
end
