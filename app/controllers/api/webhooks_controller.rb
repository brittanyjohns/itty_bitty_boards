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

    puts "Event type: #{event_type}"
    puts "Object type: #{object_type}"

    begin
      case event_type
      when "customer.subscription.created", "customer.subscription.updated"
        puts "Customer subscription created\n #{event_type}"
        puts "Subscription ID: #{data_object.id}"
        puts "Customer ID: #{data_object.customer}"
        subscription_data = {
          subscription: data_object.id,
          customer: data_object.customer,
        }

        subscription_data[:plan] = data_object.plan
        subscription_data[:product] = data_object.plan&.product
        subscription_data[:plan_type] = data_object.plan&.nickname
        subscription_data[:status] = data_object.status
        subscription_data[:trial_end] = data_object.trial_end
        subscription_data[:current_period_end] = data_object.current_period_end
        subscription_data[:current_period_start] = data_object.current_period_start
        @user = User.find_by(stripe_customer_id: data_object.customer)
        if @user
          puts "Existing user found: #{@user}"
        else
          puts "No existing user found for stripe_customer_id: #{data_object.customer}"
          return
        end
        subscription_json = subscription_data.to_json
        CreateSubscriptionJob.perform_async(subscription_json, @user) if @user
        if @user
          puts ">>> NEW Subscribed User: #{@user}"
        else
          puts "No user found for subscription"
        end

        # invoice: data_object.invoice,

      when "customer.created"
        @user = User.find_by(stripe_customer_id: data_object.id)
        if @user
          puts "Existing user found: #{@existing_user}"
        else
          puts "No existing user found for stripe_customer_id: #{data_object.id}"

          @user = User.find_by(email: data_object.email) unless @user
          if @user && @user.stripe_customer_id.nil?
            @user.stripe_customer_id = data_object.id
            @user.save!
          end
          @user = User.create_from_email(data_object.email, data_object.id) unless @user
        end
        puts ">>> NEW User Created: #{@user}"
      when "customer.subscription.trial_will_end"
        puts "Customer subscription trial will end\n #{event_type}"
        puts "Subscription ID: #{data_object.id}"
        puts "Customer ID: #{data_object.customer}"
        puts "Plan ID: #{data_object.plan.id}"
        puts "Plan type: #{data_object.plan.nickname}"
        puts "status: #{data_object.status}" # trialing
        # Send email to user
      when "customer.subscription.paused"
        puts "Customer subscription paused\n #{event_type}"
        puts "Subscription ID: #{data_object.id}"
        puts "Customer ID: #{data_object.customer}"
        puts "Plan ID: #{data_object.plan.id}"
        puts "Plan type: #{data_object.plan.nickname}"
        puts "status: #{data_object.status}" # paused
        # Send email to user
      when "customer.subscription.pending_update_applied"
        puts "Customer subscription pending update applied\n #{event_type}"
      when "customer.subscription.deleted"
        puts "Customer subscription deleted\n #{event_type}"
        puts "Subscription ID: #{data_object.id}"
        puts "Customer ID: #{data_object.customer}"
        @user = User.find_by(stripe_customer_id: data_object.customer)
        if @user
          puts "Existing user found: #{@user}"
          @user.plan_status = "canceled"
          @user.plan_type = "free"
          @user.save!
        else
          puts "No existing user found for stripe_customer_id: #{data_object.customer}"
          render json: { error: "No user found for subscription" }, status: 400 and return
        end
      when "checkout.session.completed"
        # puts "Checkout session completed\n #{event_type}"
        # puts "User UUID: #{data_object.client_reference_id}"
        # puts "Subscription ID: #{data_object.subscription}"
        stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
        # subscription_data[:current_period_end] = stripe_subscription.current_period_end
        # subscription_data[:expires_at] = stripe_subscription.current_period_end
        puts "Stripe subscription: #{stripe_subscription.inspect}"

        # user_uuid = data_object.client_reference_id
        # puts "User UUID: #{user_uuid}"
        # # raise "User UUID not found" if user_uuid.nil?
        # @user = User.find_by(uuid: user_uuid) if user_uuid
        @user = User.find_by(email: data_object.customer_details["email"]) unless @user
        # @found_user = @user
        # @user = User.create_from_email(data_object.customer_details["email"]) unless @user
        # puts ">>> User: #{@user}"
        # subscription_data = {
        #   subscription: data_object.subscription,
        #   customer: data_object.customer,
        #   customer_email: data_object.customer_email,
        # }.to_json
        # CreateSubscriptionJob.perform_async(subscription_data, @user)
        Rails.logger.info "Checkout completed. Adding 5 tokens to user #{@user}"
        @user.add_tokens(5) if @user

        # Payment is successful and the subscription is created.
        # You should provision the subscription and save the customer ID to your database.
      when "invoice.created"
        puts "Invoice created\n #{data_object.customer}"
      when "invoice.paid"
        @user = User.find_by(stripe_customer_id: data_object.customer)
        @user = User.find_by(email: data_object.customer_email) unless @user
        if @user
          puts "Existing user found: #{@user}"
        else
          puts "No existing user found for stripe_customer_id: #{data_object.customer}"
          @user = User.create_from_email(data_object.customer_email, data_object.customer) unless @user
        end
        stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
        puts "stripe_subscription: #{stripe_subscription.inspect}"
        plan_type_name = stripe_subscription.plan.nickname
        puts "Plan type name: #{plan_type_name}"
        plan_type = Subscription.get_plan_type(plan_type_name)
        # puts "Plan type: #{plan_type}"
        hosted_invoice_url = data_object.hosted_invoice_url
        if @user
          puts "Existing user found: #{@user}"
          @user.settings ||= {}
          @user.settings["hosted_invoice_url"] = hosted_invoice_url
          communicator_limit = plan_type_name.split("_").last || 1
          puts "Communicator limit: #{communicator_limit}"
          @user.settings["communicator_limit"] = communicator_limit.to_i if communicator_limit
          @user.settings["plan_nickname"] = plan_type_name

          @user.plan_type = plan_type
          @user.plan_status = data_object.status
          @user.plan_expires_at = Time.at(stripe_subscription.current_period_end)
          @user.save!
        else
          puts "No existing user found for customer: #{data_object.customer}"
        end
      when "billing_portal.session.created"
        puts "Billing portal session created\n #{event_type}"
      else
        puts "Unhandled event type: #{event.type}"
      end
    rescue StandardError => e
      puts "Error: #{e.inspect}\n #{e.backtrace}"
      render json: { error: e.inspect }, status: 400
      return
    end

    render json: { success: true }, status: 200
  end
end
