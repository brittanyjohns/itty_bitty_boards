class API::WebhooksController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[webhooks] # Allow Stripe to hit this endpoint

  def webhooks
    payload = request.body.read
    sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
    event = nil

    # Verify this came from Stripe
    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, ENV["STRIPE_WEBHOOK_SECRET"]
      )
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.inspect}"
      # Invalid payload
      render json: { error: "Invalid payload" }, status: 400
      return
    rescue Stripe::SignatureVerificationError => e
      puts "Signature error: #{e.inspect}"
      # Invalid signature
      render json: { error: "Invalid signature" }, status: 400
      return
    end

    event_type = event["type"]
    data = event["data"]
    data_object = data["object"]
    object_type = data_object["object"]

    @existing_user = User.find_by(stripe_customer_id: data_object.customer)
    if @existing_user
      puts "Existing user found: #{@existing_user}"
    else
      puts "No existing user found for customer: #{data_object.customer}"
    end
    case event_type
    when "checkout.session.completed"
      # puts "Checkout session completed\n #{event_type}"
      # puts "User UUID: #{data_object.client_reference_id}"
      # puts "Subscription ID: #{data_object.subscription}"
      stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
      # puts "Stripe subscription: #{stripe_subscription.inspect}"

      subscription_data = {
        subscription: data_object.subscription,
        customer: data_object.customer,
        invoice: data_object.invoice,
        payment_status: data_object.payment_status,
        amount_total: data_object.amount_total,
        client_reference_id: data_object.client_reference_id,
        current_period_end: stripe_subscription.current_period_end,
        expires_at: stripe_subscription.current_period_end,

      }.to_json

      CreateSubscriptionJob.perform_async(subscription_data)
      Rails.logger.info "Subscription created: #{subscription_data}\n Adding 300 tokens to user"
      user_uuid = subscription_data["client_reference_id"]
      raise "User UUID not found" if user_uuid.nil?
      @user = User.find_by(uuid: user_uuid) rescue nil
      raise "User not found" if @user.nil?
      @user.add_tokens(300)

      # Payment is successful and the subscription is created.
      # You should provision the subscription and save the customer ID to your database.
    when "invoice.paid"
      stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
      puts "stripe_subscription: #{stripe_subscription.inspect}"
      @subscription = Subscription.find_by(stripe_subscription_id: stripe_subscription.id)
      puts "Recorded subscription: #{@subscription.inspect}"
      #  TODO - Send email to user
      if @subscription
        @subscription.update(status: stripe_subscription.status, expires_at: Time.at(stripe_subscription.current_period_end))
        @user = @subscription.user
        @user.plan_expires_at = Time.at(stripe_subscription.current_period_end)
        Rails.logger.info "Subscription Paid: user: #{@user}, adding 100 tokens"
        @user.add_tokens(100)
        @user.save!
        Rails.logger.info "Subscription Paid: User: #{@user}, Tokens: #{@user.tokens}"
      else
        puts "No subscription found for stripe_subscription: #{stripe_subscription.id}"
      end
      # Continue to provision the subscription as payments continue to be made.
      # Store the status in your database and check when a user accesses your service.
      # This approach helps you avoid hitting rate limits.
    when "invoice.payment_failed"
      puts "Invoice payment failed\n #{event_type}"
      # TODO - Send email to user
      render json: { error: "Invoice payment failed" }, status: 400
      # The payment failed or the customer does not have a valid payment method.
      # The subscription becomes past_due. Notify your customer and send them to the
      # customer portal to update their payment information.
    when "customer.subscription.updated"
      puts "Customer subscription updated\n #{event_type}"
      sub_id = data_object.id
      puts "Subscription ID: #{sub_id}"
      @subscription = Subscription.find_by(stripe_subscription_id: sub_id)
      unless @subscription
        puts "No subscription found for stripe_subscription: #{sub_id}"
        return
      end
      pp data_object
      Rails.logger.info "Subscription Updated: #{data_object.inspect}"
      if data_object.cancel_at_period_end == true
        puts "Subscription will be canceled at the end of the billing period - #{data_object["current_period_end"]}"
        @subscription.cancel_at_period_end(data_object["current_period_end"])
      else
        puts "Subscription will continue"
        @subscription.update(expires_at: Time.at(data_object.current_period_end), status: data_object.status)
      end
    when "customer.subscription.deleted"
      puts "Customer subscription deleted\n #{event_type}"
      # Handle subscription cancelled automatically based
      puts "Subscription ID: #{data_object.id}"
      @subscription = Subscription.find_by(stripe_subscription_id: data_object.id)
      if @subscription&.cancel
        puts "Subscription canceled: #{@subscription.inspect}"
      else
        puts "Could not cancel subscription \n Errors: #{@subscription&.errors}"
      end
    when "billing_portal.session.created"
      puts "Billing portal session created\n #{event_type}"
    else
      puts "Unhandled event type: #{event.type}"
    end

    render json: { success: true }, status: 200
  end
end
