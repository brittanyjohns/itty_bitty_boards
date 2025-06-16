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

        Rails.logger.info "Processing subscription event: #{event_type} "
        Rails.logger.info "PLAN: #{data_object.plan&.inspect}"

        plan_nickname = data_object&.plan&.nickname || data_object&.items&.data&.first&.plan&.nickname
        Rails.logger.info "Plan nickname: #{plan_nickname}"
        if plan_nickname.nil?
          render json: { error: "Plan nickname is nil for subscription." }, status: 400 and return
        end

        if @user
          Rails.logger.info "Existing user found: #{@user}"
          if @user.invited_by_id
            Rails.logger.info "User was invited by another user - not sending welcome email"
          else
            Rails.logger.info "User was not invited by another user - sending welcome email @user.should_send_welcome_email?: #{@user.should_send_welcome_email?}"
            @user.send_welcome_email if @user.should_send_welcome_email? && regular_plan?(plan_nickname)
          end
        else
          stripe_customer = Stripe::Customer.retrieve(data_object.customer)
          deleted = stripe_customer.deleted? if stripe_customer
          if deleted
            puts "Stripe customer is deleted: #{stripe_customer.id}"
            render json: { error: "Stripe customer is deleted." }, status: 400 and return
          end
          Rails.logger.info "Stripe customer is not deleted: #{stripe_customer.id}" if stripe_customer && !deleted
          Rails.logger.info "Stripe customer email: #{stripe_customer.email}" if stripe_customer
          Rails.logger.info "No existing user found for stripe_customer_id - Creating one: #{data_object.customer}" if stripe_customer
          Rails.logger.info "Stripe customer: #{stripe_customer.inspect}" if stripe_customer
          @user = User.find_by(email: stripe_customer.email) unless @user
          Rails.logger.info "Found user by email: #{@user.email}" if @user
          if @user
            @user.stripe_customer_id = data_object.customer
            Rails.logger.info "Updating existing user with new stripe_customer_id: #{data_object.customer}"
            @user.save!
          end
          stripe_customer_id = data_object.customer || stripe_customer.id
          if plan_nickname&.include?("myspeak")
            @user = handle_myspeak_user(stripe_customer.email, stripe_customer_id)
          elsif plan_nickname&.include?("vendor")
            business_name = stripe_customer.metadata["business_name"] || nil
            Rails.logger.info "Handling vendor user with business name: #{business_name}"
            @user = handle_vendor_user(stripe_customer.email, business_name, stripe_customer_id)
          else
            Rails.logger.info "Creating user from email: #{stripe_customer.email} with stripe_customer_id: #{stripe_customer_id}"
            @user = User.create_from_email(stripe_customer.email, stripe_customer_id) unless @user
          end
        end
        subscription_json = subscription_data.to_json
        sub_items = data_object&.items&.data
        Rails.logger.info "Subscription items: #{sub_items.inspect}" if sub_items
        @user.update_from_stripe_event(subscription_data, plan_nickname) if @user

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
            # if plan_nickname&.include?("myspeak")
            #   @user = handle_myspeak_user(data_object.email, data_object.id)
            # elsif plan_nickname&.include?("vendor")
            #   business_name = data_object.metadata["business_name"] || "Vendor for #{data_object.email}"
            #   @user = handle_vendor_user(data_object.email, business_name, data_object.id)
            # else
            #   @user = User.create_from_email(data_object.email, data_object.id) unless @user
            # end
          elsif @user && data_object.id && @user.stripe_customer_id == data_object.id
            puts "User already exists with stripe_customer_id: #{data_object.id}"
            render json: { success: true }, status: 304 and return
          else
            # if plan_nickname&.include?("myspeak")
            #   @user = handle_myspeak_user(data_object.email, data_object.id)
            # elsif plan_nickname&.include?("vendor")
            #   business_name = data_object.metadata["business_name"] || "Vendor for #{data_object.email}"
            #   @user = handle_vendor_user(data_object.email, business_name, data_object.id)
            # else
            #   @user = User.create_from_email(data_object.email, data_object.id) unless @user
            # end
            unless @user
              render json: { error: "No user found for subscription" }, status: 400 and return
            end
            puts "Created new user with stripe_customer_id: #{data_object.id}"
            render json: { success: true }, status: 200 and return
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
        Rails.logger.debug "data_object: #{data_object.inspect}"

        session = data_object
        Rails.logger.info "Checkout session completed: #{session.inspect}"
        @user = User.find_by(stripe_customer_id: session.customer)
        Rails.logger.debug " Data object: #{session.inspect}"
        custom_fields = session.custom_fields
        Rails.logger.debug "Custom fields: #{custom_fields.inspect}"
        custom_field = custom_fields.first
        Rails.logger.debug "Custom field: #{custom_field.inspect}"
        if custom_field
          if custom_field["key"] == "businessname"
            email = session.customer_details["email"]
            @user ||= User.find_by(email: email) unless @user
            @vendor = Vendor.find_by(user_id: @user.id) if @user
            @vendor ||= Vendor.find_by(business_email: email) unless @vendor
            Rails.logger.info "Found vendor: #{@vendor.inspect}" if @vendor
            if @vendor.nil? && custom_field["text"] && custom_field["text"]["value"].present?
              business_name = custom_field["text"]["value"]
              Rails.logger.info "Creating new vendor with business name: #{business_name}"
              @user = handle_vendor_user(email, business_name, session.customer)
              if @user.nil?
                Rails.logger.error "Failed to create vendor user for email: #{email}"
                render json: { error: "Failed to create vendor user." }, status: 400 and return
              end
              @user.reload
              @vendor = @user.vendor
              Rails.logger.info "New vendor created: #{@vendor.inspect}" if @vendor
            end
            if @vendor && custom_field["text"] && custom_field["text"]["value"].present?
              value = custom_field["text"]["value"]
              Rails.logger.info "Updating existing vendor with business name: #{value}"
              @vendor.business_name = value
              @vendor.save!
            else
              Rails.logger.error "No existing vendor found for user: #{@user.id}"
            end
          end
        end
        unless @user
          puts "No existing user found for stripe_customer_id - Nothing to add tokens: #{data_object.customer}"
          render json: { error: "No user found for payment intent" }, status: 400 and return
        end

        # Payment is successful and the subscription is created.
        # You should provision the subscription and save the customer ID to your database.
      when "invoice.created"
        # when "invoice.paid"
        #   @user = User.find_by(stripe_customer_id: data_object.customer)
        #   @user = User.find_by(email: data_object.customer_email) unless @user
        #   unless @user
        #     puts "No existing user found for stripe_customer_id: #{data_object.customer}"
        #     begin
        #       @user = User.create_from_email(data_object.customer_email, data_object.customer) unless @user
        #     rescue ActiveRecord::RecordInvalid => e
        #       Rails.logger.error "invoice.paid -> Error creating user from email: #{e.inspect}"
        #       render json: { error: "Error creating user from email." }, status: 400 and return
        #     end
        #     unless @user
        #       render json: { error: "No user found for subscription" }, status: 400 and return
        #     end
        #   end
        #   stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)
        #   plan_type_name = stripe_subscription&.plan&.nickname || stripe_subscription&.items&.data&.first&.plan&.nickname

        #   hosted_invoice_url = data_object.hosted_invoice_url
        #   if @user
        #     subscription_data = {
        #       subscription: data_object.subscription,
        #       customer: data_object.customer,
        #       hosted_invoice_url: hosted_invoice_url,
        #       plan_nickname: plan_type_name,
        #       plan: stripe_subscription.plan,
        #     }
        #     @user.update_from_stripe_event(subscription_data, plan_type_name)
        #     @user.stripe_customer_id = data_object.customer if data_object.customer
        #     @user.save!
        #   else
        #     puts "No existing user found for customer: #{data_object.customer}"
        #   end
        # end
      end
    rescue StandardError => e
      Rails.logger.error "Error: #{e.inspect}\n #{e.backtrace}"
      render json: { error: e.inspect }, status: 400
      return
    end

    render json: { success: true }, status: 200
  end

  private

  def handle_myspeak_user(email, stripe_customer_id)
    begin
      temp_slug = stripe_customer.email.split("@").first
      temp_slug = temp_slug.parameterize
      puts "Creating new user temp_slug: #{temp_slug}"
      @user = User.create_from_email(email, stripe_customer_id, nil, temp_slug) unless @user
      @user.plan_type = "myspeak"
      @user.plan_status = "active"
      @user.save!
      @profile = Profile.generate_with_username(temp_slug, @user) if @user
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Error creating user from email: #{e.inspect}"
    rescue StandardError => e
      Rails.logger.error "Error handling myspeak user: #{e.inspect}"
    end
    if @user
      puts "Myspeak user created successfully: #{@user.email}"
    else
      Rails.logger.error "Error creating myspeak user from email: #{email}"
    end
    @user.stripe_customer_id = stripe_customer_id if stripe_customer_id
    @user.save! if @user
    @user
  rescue StandardError => e
    Rails.logger.error "Error handling myspeak user: #{e.inspect}"
    nil
  end

  def handle_vendor_user(email, business_name, stripe_customer_id = nil)
    Rails.logger.debug "Handling vendor user for email: #{email} with stripe_customer_id: #{stripe_customer_id}"
    begin
      @vendor = Vendor.find_or_create_by(business_email: email, user_id: nil)
      if @vendor.business_name.blank? && business_name.present?
        Rails.logger.info "Setting business name for vendor: #{business_name}"
        @vendor.business_name = business_name
      end
      @vendor.verified = true
      @vendor.description = "Welcome to #{@vendor.business_name}. Please complete your profile."
      @user = User.create_new_vendor_user(email, business_name, stripe_customer_id) unless @user
      if @user
        @user.plan_type = "vendor"
        @user.plan_status = "active"
        @user.save!
        @vendor.user = @user

        @vendor.save!
      else
        Rails.logger.error "Error creating vendor user from email: #{email}"
      end
      @vendor.create_profile! if @vendor
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Error creating vendor user from email: #{e.inspect}"
    rescue StandardError => e
      Rails.logger.error "Error handling vendor user: #{e.inspect}"
    end
    @user.stripe_customer_id = stripe_customer_id if stripe_customer_id
    @user.save! if @user
    @user
  end

  def regular_plan?(plan_nickname)
    Rails.logger.info "Checking if plan is regular: #{plan_nickname}"
    return false if plan_nickname.nil?
    regular_plans = ["free", "basic", "pro", "premium"]
    regular_plans.any? { |plan| plan_nickname.downcase.include?(plan) }
  rescue StandardError => e
    Rails.logger.error "Error checking regular plan: #{e.inspect}"
    false
  end
end
