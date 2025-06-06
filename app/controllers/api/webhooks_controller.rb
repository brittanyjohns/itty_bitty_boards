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

    begin
      case event_type
      when "customer.subscription.paused"
        @user = User.find_by(stripe_customer_id: data_object.customer)
        if @user
          puts "Existing user found: #{@user}"
          @user.plan_status = "paused"
          @user.plan_type = "free"
          @user.save!
        else
          puts "No existing user found for stripe_customer_id - Nothing to pause: #{data_object.customer}"
          render json: { error: "No user found for subscription" }, status: 400 and return
        end
      when "customer.subscription.created", "customer.subscription.updated"
        subscription_data = {
          subscription: data_object.id,
          customer: data_object.customer,
        }

        subscription_data[:plan] = data_object.plan
        subscription_data[:interval] = data_object.plan.interval
        subscription_data[:product] = data_object.plan&.product
        subscription_data[:plan_type] = data_object.plan&.nickname
        subscription_data[:status] = data_object.status
        subscription_data[:trial_end] = data_object.trial_end
        subscription_data[:current_period_end] = data_object.current_period_end
        subscription_data[:current_period_start] = data_object.current_period_start
        subscription_data[:cancel_at_period_end] = data_object.cancel_at_period_end
        subscription_data[:cancel_at] = data_object.cancel_at

        @user = User.find_by(stripe_customer_id: data_object.customer)

        pp data_object

        if @user
          puts "Existing user found: #{@user}"
          if @user.invited_by_id
            puts "User was invited by another user - not sending welcome email"
          else
            puts "User was not invited by another user - sending welcome email"
            @user.send_welcome_email if @user.should_send_welcome_email?
          end
        else
          stripe_customer = Stripe::Customer.retrieve(data_object.customer)
          @user = User.find_by(email: stripe_customer.email) unless @user
          if @user
            @user.stripe_customer_id = data_object.customer
            @user.save!
          end
          stripe_customer_id = data_object.customer || stripe_customer.id

          @user = User.create_from_email(stripe_customer.email, stripe_customer_id) unless @user
        end
        subscription_json = subscription_data.to_json
        sub_items = data_object&.items&.data
        plan_nickname = data_object&.plan&.nickname || data_object&.items&.data&.first&.plan&.nickname
        @user.update_from_stripe_event(subscription_data, plan_nickname) if @user
        # CreateSubscriptionJob.perform_async(subscription_json, @user.id) if @user
        if @user
          render json: { success: true }, status: 200 and return
        else
          render json: { error: "No user found for subscription" }, status: 400 and return unless @user
        end
      when "customer.created"
        @user = User.find_by(stripe_customer_id: data_object.id)
        if @user
          puts "Existing user found: #{@existing_user}"
        else
          puts "No existing user found for stripe_customer_id - Creating one: #{data_object.id}"

          @user = User.find_by(email: data_object.email) unless @user
          if @user && data_object.id && @user.stripe_customer_id != data_object.id
            puts "Updating existing user with new stripe_customer_id: #{data_object.id}"
            @user.stripe_customer_id = data_object.id
            @user.save!
            @user = User.create_from_email(data_object.email, data_object.id) unless @user
          elsif @user && data_object.id && @user.stripe_customer_id == data_object.id
            puts "User already exists with stripe_customer_id: #{data_object.id}"
            render json: { success: true }, status: 304 and return
          else
            puts "Creating new user with stripe_customer_id: #{data_object.id}"
            @user = User.create_from_email(data_object.email, data_object.id) unless @user
            unless @user
              render json: { error: "No user found for subscription" }, status: 400 and return
            end
            @user.stripe_customer_id = data_object.id
            @user.save!
          end
        end
      when "customer.subscription.deleted"
        @user = User.find_by(stripe_customer_id: data_object.customer)
        if @user
          @user.plan_status = "canceled"
          @user.plan_type = "free"
          @user.save!
        else
          puts "No existing user found for stripe_customer_id - Nothing to cancel: #{data_object.customer}"
          render json: { error: "No user found for subscription" }, status: 400 and return
        end
      when "checkout.session.completed"
        stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)

        @user = User.find_by(email: data_object.customer_details["email"]) unless @user

        Rails.logger.info "Checkout completed. Adding 5 tokens to user #{@user}"
        @user.add_tokens(5) if @user

        # Payment is successful and the subscription is created.
        # You should provision the subscription and save the customer ID to your database.
      when "invoice.created"
      when "invoice.paid"
        @user = User.find_by(stripe_customer_id: data_object.customer)
        @user = User.find_by(email: data_object.customer_email) unless @user
        unless @user
          puts "No existing user found for stripe_customer_id: #{data_object.customer}"
          begin
            @user = User.create_from_email(data_object.customer_email, data_object.customer) unless @user
          rescue ActiveRecord::RecordInvalid => e
            Rails.logger.error "invoice.paid -> Error creating user from email: #{e.inspect}"
            render json: { error: "Error creating user from email." }, status: 400 and return
          end
          unless @user
            render json: { error: "No user found for subscription" }, status: 400 and return
          end
        end
        stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
        plan_type_name = stripe_subscription&.plan&.nickname || stripe_subscription&.items&.data&.first&.plan&.nickname

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
          @user.stripe_customer_id = data_object.customer if data_object.customer
          @user.save!
        else
          puts "No existing user found for customer: #{data_object.customer}"
        end
      end
    rescue StandardError => e
      Rails.logger.error "Error: #{e.inspect}\n #{e.backtrace}"
      render json: { error: e.inspect }, status: 400
      return
    end

    render json: { success: true }, status: 200
  end
end
