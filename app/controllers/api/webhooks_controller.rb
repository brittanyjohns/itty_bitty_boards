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
    Rails.logger.info "Received Stripe webhook event: #{event_type} for object type: #{object_type} \n data class: #{data_object.class}"

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
      when "customer.subscription.created"
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
          Rails.logger.warn "No plan nickname found in subscription data"
          plan_nickname = "free"
        end
        stripe_customer = Stripe::Customer.retrieve(data_object.customer)

        if @user
          Rails.logger.info "Existing user found: #{@user}"
          if @user.invited_by_id
            Rails.logger.info "User was invited by another user - not sending welcome email"
          else
            if regular_plan?(plan_nickname)
              Rails.logger.info "Sending welcome email to user: #{@user.email} for plan: #{plan_nickname}"
              @user.send_welcome_email(plan_nickname)
              Rails.logger.info "Welcome email sent to user: #{@user.email} for plan: #{plan_nickname}"
            else
              Rails.logger.warn "Skipping welcome email for plan: #{plan_nickname}"
              if plan_nickname&.include?("myspeak")
                unless @user.plan_type == "pro" || @user.plan_type == "basic"
                  @user.plan_type = "myspeak"
                end
                @user.plan_status = "active"
                @user.save!
                # Rails.logger.info "Handling myspeak user for plan: #{plan_nickname}"
                # @user = handle_myspeak_user(stripe_customer)
                # Rails.logger.info "Myspeak user handled: #{@user&.email} with stripe_customer_id: #{stripe_customer.id}" if @user
                Rails.logger.info "Skip myspeak user for plan: #{plan_nickname}"
              elsif plan_nickname&.include?("vendor")
                Rails.logger.info "Skip vendor user for plan: #{plan_nickname}"
              else
                Rails.logger.info "Regular user for plan: #{plan_nickname}"
                @user.update_from_stripe_event(subscription_data, plan_nickname)
                Rails.logger.info "User updated from Stripe event: #{@user&.email} with plan type: #{@user.plan_type}"
              end
            end
          end
        else
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
            # @user = handle_myspeak_user(stripe_customer)
            Rails.logger.info "Handling myspeak user for plan: #{plan_nickname}"
          elsif plan_nickname&.include?("vendor")
            # @user = handle_vendor_user(stripe_customer.email, nil, stripe_customer_id, plan_nickname)
            Rails.logger.info "Vendor user for plan: #{plan_nickname} - not handled yet"
            render json: { success: true }, status: 200 and return
          else
            Rails.logger.info "Creating regular user: #{stripe_customer&.email} with stripe_customer_id: #{stripe_customer_id}"
            @user = User.create_from_email(stripe_customer.email, stripe_customer_id) unless @user
          end
        end
        subscription_json = subscription_data.to_json
        sub_items = data_object&.items&.data
        @user.update_from_stripe_event(subscription_data, plan_nickname) if @user

        if @user
          render json: { success: true }, status: 200 and return
        else
          render json: { error: "No user found for subscription" }, status: 400 and return
        end
      when "customer.created"
        Rails.logger.info "Customer created event received: #{data_object["email"]}"
      when "customer.subscription.updated"
        @user = User.find_by(stripe_customer_id: data_object.customer)
        if @user
          Rails.logger.info "Update event received for user: #{@user.email} with plan type: #{data_object.plan&.nickname}"
          if @user.update_from_stripe_event(data_object, data_object.plan&.nickname)
            render json: { success: true }, status: 200 and return
          else
            Rails.logger.error "Failed to update user from Stripe event: #{data_object.customer}"
            render json: { error: "Failed to update user from Stripe event" }, status: 400 and return
          end
        else
          Rails.logger.error "No existing user found for stripe_customer_id - Nothing to update: #{data_object.customer}"
          render json: { error: "No user found for subscription" }, status: 400 and return
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

        session = data_object
        custom_fields = session.custom_fields
        metadata = session.metadata || {}
        plan_type = metadata["plan_type"]
        Rails.logger.info "Processing checkout session completed event: #{event_type} for user: #{@user&.email} with plan type: #{plan_type}"
        Rails.logger.info "Session metadata: #{metadata.inspect}"
        Rails.logger.info "Checkout session completed for user: #{@user&.email} with custom fields: #{custom_fields.inspect}"
        # unless plan_type == "vendor"
        #   Rails.logger.info "Plan type is not vendor: #{plan_type} - skipping vendor user creation"
        #   render json: { success: true }, status: 200 and return
        # end
        @user = User.find_by(stripe_customer_id: session.customer) unless @user

        Rails.logger.debug "User found: #{@user&.email} - stripe_customer_id: #{session.customer}" if @user
        if plan_type == "vendor"
          Rails.logger.info "Handling vendor user for plan: #{plan_type}"
          if @user.nil?
            Rails.logger.error "No user found for stripe_customer_id: #{data_object.customer}"
            @user = User.create_from_email(
              session.customer_details["email"],
              session.customer,
              nil,
              nil
            )
            Rails.logger.info "Created new user: #{@user&.email} with stripe_customer_id: #{session.customer}"
            if @user.nil?
              Rails.logger.error "Failed to create user for email: #{session.customer_details["email"]}"
              render json: { error: "Failed to create user." }, status: 400 and return
            end
            @user.plan_type = plan_type || "free"
            @user.role = "vendor"
            @user.plan_status = "active"
            @user.save!
            Rails.logger.info "New user created: #{@user&.email} with plan type: #{@user.plan_type}"
          end
          plan_nickname = "vendor_#{plan_type}" if plan_type
          Rails.logger.info "Plan nickname for vendor: #{plan_nickname}"
        elsif plan_type == "myspeak"
          Rails.logger.info "Handling myspeak user for plan: #{plan_type}"

          Rails.logger.info "Myspeak user handled: #{@user&.email} with stripe_customer_id: #{session.customer}" if @user
          plan_nickname = "myspeak_#{@user&.plan_type}" if @user&.plan_type
          Rails.logger.info "Plan nickname for myspeak: #{plan_nickname}"
        end
        custom_fields.each do |custom_field|
          if custom_field
            if custom_field["key"] == "businessname"
              email = session.customer_details["email"]
              business_name = custom_field["text"]["value"]
              @user ||= User.find_by(email: email)
              Rails.logger.info "Processing business name #{business_name} for email: #{email}"
              @vendor = Vendor.find_by(user_id: @user.id) if @user
              @vendor ||= Vendor.find_by(business_email: email) unless @vendor
              Rails.logger.info "Found vendor: #{@vendor&.business_email} for user: #{@user&.email}" if @vendor
              if @vendor.nil? && custom_field["text"] && custom_field["text"]["value"].present?
                Rails.logger.info "Creating new vendor user for email: #{email} with business name: #{business_name}"
                if @user
                  Rails.logger.info "User already exists: #{@user.email} - plan type: #{@user.plan_type}"
                  plan_nickname = "vendor_#{@user.plan_type}" if @user.plan_type
                else
                  Rails.logger.info "Creating new FREE Vendor user for email: #{email} - plan_nickname: #{plan_nickname}"
                  # plan_nickname = "vendor_free"
                end

                @vendor = @user.vendor
              elsif @vendor && custom_field["text"] && custom_field["text"]["value"].present?
                Rails.logger.info "Updating existing vendor user for email: #{email} with business name: #{business_name}"
                @vendor ||= Vendor.find_by(business_email: email)
                @vendor.business_name = business_name
                @vendor.save!
              else
                Rails.logger.error "No existing vendor found for user: #{@user.id}"
              end
              Rails.logger.info "Creating vendor user with email: #{email}, business_name: #{business_name}, stripe_customer_id: #{session.customer}, plan_nickname: #{plan_nickname}"
              @user = handle_vendor_user(email, business_name, session.customer, plan_nickname)
              @user = User.find_by(email: email) unless @user
              Rails.logger.info "Vendor user created: #{@user&.email} with business name: #{@vendor&.business_name} and stripe_customer_id: #{session.customer} - plan_nickname: #{plan_nickname} - plan_type: #{@user&.plan_type}" if @user
              Rails.logger.info "SESSION COMPLETE #{@user&.email} with business name: #{@vendor&.business_name} and stripe_customer_id: #{session.customer} - plan_nickname: #{plan_nickname} - plan_type: #{@user&.plan_type}"
              if @user.nil?
                Rails.logger.error "Failed to create vendor user for email: #{email}"
                render json: { error: "Failed to create vendor user." }, status: 400 and return
              end
              @user.vendor ||= @vendor
              render json: { success: true }, status: 200 and return
            end
            if custom_field["key"] == "username"
              email = session.customer_details["email"]
              myspeak_slug = custom_field["text"]["value"]
              @user = handle_myspeak_user(session, myspeak_slug) if myspeak_slug.present?
              Rails.logger.info "Processing myspeak slug #{myspeak_slug} for email: #{email}"
              if @user.nil?
                Rails.logger.info "Creating new myspeak user for email: #{email} with slug: #{myspeak_slug}"
                @user = User.create_from_email(email, session.customer, nil, myspeak_slug)
              else
                Rails.logger.info "Created myspeak user: #{@user.email} with slug: #{myspeak_slug}"
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

  def handle_myspeak_user(stripe_session, slug = nil)
    begin
      stripe_customer_id = stripe_session.customer
      email = stripe_session.customer_details["email"]
      # email = stripe_customer.email
      # stripe_customer_id = stripe_customer.id
      if slug.nil?
        slug = email.split("@").first.parameterize
      end
      slug = slug
      # @user = User.create_from_email(email, stripe_customer_id, nil, slug) unless @user
      @user = User.find_by(email: email)
      found_user = @user
      Rails.logger.info "Found user: #{found_user&.email} for email: #{email}" if found_user
      @user = User.invite!(email: email, skip_invitation: true) unless @user
      @user.send_welcome_with_claim_link_email(slug)
      Rails.logger.info "Myspeak user created: #{@user.email} with slug: #{slug}"
      @user.plan_type = "myspeak"
      @user.plan_status = "active"
      @user.stripe_customer_id = stripe_customer_id if stripe_customer_id
      @user.settings ||= {}
      @user.settings[:myspeak_slug] = slug
      @user.settings["board_limit"] = 1
      @user.settings["communicator_limit"] = 0
      @user.save!
      @profile = Profile.generate_with_username(slug, @user) if @user
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
    unless email.present? && business_name.present?
      Rails.logger.error "handle_vendor_user - Missing email or business_name: email: #{email}, business_name: #{business_name}"
      return nil
    end
    @user = User.find_by(email: email)
    if @user
      Rails.logger.info "handle_vendor_user - Found existing user: #{@user.email} for email: #{email}"
      if @user.vendor
        Rails.logger.info "handle_vendor_user - User already has a vendor: #{@user.vendor.business_email}"
        @vendor = @user.vendor
        Rails.logger.info "handle_vendor_user - Updated existing vendor: #{@vendor.business_email} with business name: #{@vendor.business_name}"
      else
        Rails.logger.info "handle_vendor_user - User does not have a vendor, creating new one"
      end
    end

    Rails.logger.debug "Handling vendor user for email: #{email} with stripe_customer_id: #{stripe_customer_id}"
    begin
      @vendor = Vendor.find_or_create_by(business_email: email, user_id: @user&.id) unless @vendor
      if @vendor.business_name.blank?
        @vendor.business_name = business_name
      end
      @vendor.verified = !business_name.blank?
      @vendor.configuration ||= {}

      @vendor.description = "Welcome to #{@vendor.business_name}. Please complete your profile."
      @user = User.create_new_vendor_user(email, @vendor, stripe_customer_id, plan_nickname)

      Rails.logger.info "User.create_new_vendor_user ==> handle_vendor_user: plan_nickname: #{plan_nickname}"

      if @user
        @vendor.user = @user
        @vendor.save!
        @user.stripe_customer_id = stripe_customer_id if stripe_customer_id
        @user.save!
        Rails.logger.info "handle_vendor_user - Created vendor user: #{@user.email} with business name: #{@vendor.business_name} and stripe_customer_id: #{stripe_customer_id}"
      else
        Rails.logger.debug "handle_vendor_user - No User for email: #{email}"
      end

      @vendor_profile = @vendor.create_profile! if @vendor
      Rails.logger.info "handle_vendor_user - Vendor profile created for: #{@vendor.business_email} with business name: #{@vendor.business_name}" if @vendor_profile
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "handle_vendor_user - Error creating vendor user from email: #{e.inspect}"
    rescue StandardError => e
      Rails.logger.error "handle_vendor_user - Error handling vendor user: #{e.inspect}"
    end

    if @user
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
