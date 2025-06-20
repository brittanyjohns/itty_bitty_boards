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
      Rails.logger.error "Error parsing JSON: #{e.inspect}"
      # Invalid payload
      render json: { error: "Invalid payload" }, status: 400
      return
    rescue Stripe::SignatureVerificationError => e
      Rails.logger.error "Signature error: #{e.inspect}"
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
          @user.plan_status = "paused"
          @user.plan_type = "free"
          @user.save!
        else
          Rails.logger.error "No existing user found for stripe_customer_id - Nothing to pause: #{data_object.customer}"
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
            render json: { error: "Stripe customer was deleted." }, status: 400 and return
          end

          @user = User.find_by(email: stripe_customer.email) unless @user
          if @user
            @user.stripe_customer_id = data_object.customer
            @user.save!
          end
          stripe_customer_id = data_object.customer || stripe_customer.id
          if plan_nickname&.include?("myspeak")
            @user = handle_myspeak_user(stripe_customer.email, stripe_customer_id)
          elsif plan_nickname&.include?("vendor")
            # @user = handle_vendor_user(stripe_customer.email, nil, stripe_customer_id, plan_nickname)

            Rails.logger.info "xxxxCreated vendor user: #{@user&.email} with stripe_customer_id: #{stripe_customer_id}"
          else
            @user = User.create_from_email(stripe_customer.email, stripe_customer_id) unless @user
          end
        end
        subscription_json = subscription_data.to_json
        sub_items = data_object&.items&.data
        @user.update_from_stripe_event(subscription_data, plan_nickname) if @user

        if @user
          render json: { success: true }, status: 200 and return
        else
          render json: { error: "No user found for subscription" }, status: 400 and return unless @user
        end
      when "customer.created"
        @user = User.find_by(stripe_customer_id: data_object.id)
        unless @user
          @user = User.find_by(email: data_object.email)
          if @user && data_object.id && @user.stripe_customer_id != data_object.id
            @user.stripe_customer_id = data_object.id
            @user.save!
          elsif @user && data_object.id && @user.stripe_customer_id == data_object.id
            Rails.logger.debug "User already exists with stripe_customer_id: #{data_object.id}"
            render json: { success: true }, status: 304 and return
          else
            unless @user
              render json: { error: "No user found for subscription" }, status: 400 and return
            end
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
          Rails.logger.error "No existing user found for stripe_customer_id - Nothing to cancel: #{data_object.customer}"
          render json: { error: "No user found for subscription" }, status: 400 and return
        end
      when "checkout.session.completed"
        stripe_subscription = Stripe::Subscription.retrieve(data_object.subscription)

        @user = User.find_by(email: data_object.customer_details["email"]) unless @user
        @user ||= User.find_by(stripe_customer_id: data_object.customer)

        Rails.logger.info "stripe_subscription: #{stripe_subscription.inspect}"
        Rails.logger.debug "User found by email: #{@user&.email} - stripe_customer_id: #{data_object.customer}"

        session = data_object
        @user = User.find_by(stripe_customer_id: session.customer)
        custom_fields = session.custom_fields
        metadata = session.metadata || {}
        plan_type = metadata["plan_type"]
        Rails.logger.info "Processing checkout session completed event for user: #{@user&.email} with plan type: #{plan_type}"
        Rails.logger.info "Session metadata: #{metadata.inspect}"
        Rails.logger.info "Checkout session completed for user: #{@user&.email} with custom fields: #{custom_fields.inspect}"
        custom_fields.each do |custom_field|
          if custom_field
            if custom_field["key"] == "businessname"
              email = session.customer_details["email"]
              @user ||= User.find_by(email: email)
              Rails.logger.info "Processing business name for email: #{email} - user: #{@user&.email}"
              @vendor = Vendor.find_by(user_id: @user.id) if @user
              @vendor ||= Vendor.find_by(business_email: email) unless @vendor
              Rails.logger.info "Found vendor: #{@vendor&.business_email} for user: #{@user&.email}" if @vendor
              if @vendor.nil? && custom_field["text"] && custom_field["text"]["value"].present?
                business_name = custom_field["text"]["value"]
                Rails.logger.info "Creating new vendor user for email: #{email} with business name: #{business_name}"
                plan_nickname = "vendor_#{plan_type}" if plan_type
                if @user
                  Rails.logger.info "User already exists: #{@user.email} - plan type: #{@user.plan_type}"
                  plan_nickname = "vendor_#{@user.plan_type}" if @user.plan_type
                else
                  Rails.logger.info "Creating new FREE Vendor user for email: #{email} - plan_nickname: #{plan_nickname}"
                  # plan_nickname = "vendor_free"
                end
                Rails.logger.info "Plan nickname for vendor user: #{plan_nickname} - user: #{@user&.email} - business name: #{business_name}"

                Rails.logger.info "Creating vendor user with email: #{email}, business_name: #{business_name}, stripe_customer_id: #{session.customer}, plan_nickname: #{plan_nickname}"
                @user = handle_vendor_user(email, business_name, session.customer, plan_nickname)
                Rails.logger.info "SESSION COMPLETE #{@user&.email} with business name: #{@vendor&.business_name} and stripe_customer_id: #{session.customer}"
                if @user.nil?
                  Rails.logger.error "Failed to create vendor user for email: #{email}"
                  render json: { error: "Failed to create vendor user." }, status: 400 and return
                end
                @vendor = @user.vendor
              elsif @vendor && custom_field["text"] && custom_field["text"]["value"].present?
                value = custom_field["text"]["value"]
                @vendor.business_name = value
                @vendor.save!
              else
                Rails.logger.error "No existing vendor found for user: #{@user.id}"
              end
            end
          end
        end
        unless @user
          Rails.logger.error "No existing user found for stripe_customer_id - Nothing to add tokens: #{data_object.customer}"
          render json: { error: "No user found for payment intent" }, status: 400 and return
        end
      when "invoice.created"
        Rails.logger.info "Invoice created event received: #{data_object["customer_name"]}"
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
    unless @user
      Rails.logger.error "Error creating myspeak user from email: #{email}"
      return nil
    end
    @user.stripe_customer_id = stripe_customer_id if stripe_customer_id
    @user.save! if @user
    @user
  rescue StandardError => e
    Rails.logger.error "Error handling myspeak user: #{e.inspect}"
    nil
  end

  def handle_vendor_user(email, business_name, stripe_customer_id = nil, plan_nickname = nil)
    temp_business_name = ERB::Util.url_encode(email)
    business_name_to_use = business_name || temp_business_name

    Rails.logger.debug "Handling vendor user for email: #{email} with stripe_customer_id: #{stripe_customer_id}"
    begin
      @vendor = Vendor.find_or_create_by(business_email: email, user_id: nil)
      if @vendor.business_name.blank? && business_name_to_use.present?
        @vendor.business_name = business_name_to_use
      end
      @vendor.verified = !business_name.blank?
      @vendor.configuration ||= {}

      @vendor.description = "Welcome to #{@vendor.business_name}. Please complete your profile."
      @user = User.find_by(email: email)
      @user = User.create_new_vendor_user(email, @vendor, stripe_customer_id, plan_nickname)

      Rails.logger.info "handle_vendor_user: plan_nickname: #{plan_nickname}"

      if @user
        @vendor.user = @user
        @vendor.save!
      else
        Rails.logger.debug "handle_vendor_user - No User for email: #{email}"
      end
      @user.send_welcome_new_vendor(@vendor) if @user && @vendor && business_name
      @vendor_profile = @vendor.create_profile! if @vendor
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "handle_vendor_user - Error creating vendor user from email: #{e.inspect}"
    rescue StandardError => e
      Rails.logger.error "handle_vendor_user - Error handling vendor user: #{e.inspect}"
    end

    if @user
      @user.stripe_customer_id = stripe_customer_id if stripe_customer_id
      @user.save!
    else
      Rails.logger.error "handle_vendor_user - Error creating vendor user from email: #{email}"
      return nil
    end
    Rails.logger.info "Vendor user created successfully: #{@vendor.business_email} with business name: #{@vendor.business_name}"
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
