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
        subscription_data[:cancel_at_period_end] = data_object.cancel_at_period_end
        subscription_data[:cancel_at] = data_object.cancel_at
        @user = User.find_by(stripe_customer_id: data_object.customer)
        if @user
          puts "Existing user found: #{@user}"
        else
          puts "No existing user found for stripe_customer_id: #{data_object.customer}"
          return
        end
        subscription_json = subscription_data.to_json
        @user.update_from_stripe_event(subscription_data, data_object.plan&.nickname) if @user
        # CreateSubscriptionJob.perform_async(subscription_json, @user.id) if @user
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
      when "customer.subscription.deleted"
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

        @user = User.find_by(email: data_object.customer_details["email"]) unless @user

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
          render json: { error: "No user found for subscription" }, status: 400 and return
          # @user = User.create_from_email(data_object.customer_email, data_object.customer) unless @user
        end
        stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
        plan_type_name = stripe_subscription.plan.nickname
        puts "Plan type name: #{plan_type_name}"
        # plan_type = Subscription.get_plan_type(plan_type_name)
        # puts "Plan type: #{plan_type}"
        hosted_invoice_url = data_object.hosted_invoice_url
        if @user
          subscription_data = {
            subscription: data_object.subscription,
            customer: data_object.customer,
            hosted_invoice_url: hosted_invoice_url,
            plan_nickname: plan_type_name,
            plan: stripe_subscription.plan,
          }
          @user.update_from_stripe_event(subscription_data, plan_type_name)
          puts ">>> NEW Subscribed User: #{@user}"
        else
          puts "No existing user found for customer: #{data_object.customer}"
        end
      end
    rescue StandardError => e
      puts "Error: #{e.inspect}\n #{e.backtrace}"
      render json: { error: e.inspect }, status: 400
      return
    end

    render json: { success: true }, status: 200
  end
end
