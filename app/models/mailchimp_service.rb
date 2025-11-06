class MailchimpService
  def initialize
    @client = MailchimpClient.client
  end

  def subscriber_hash(email)
    Digest::MD5.hexdigest(email.downcase)
  end

  def record_signin_event(user, opts = {})
    props = opts[:properties] || {}
    props[:current_sign_in_ip] = user.current_sign_in_ip&.to_s if user.current_sign_in_ip
    props[:current_sign_in_at] = user.current_sign_in_at&.to_s if user.current_sign_in_at
    props[:last_sign_in_ip] = user.last_sign_in_ip&.to_s if user.last_sign_in_ip
    props[:last_sign_in_at] = user.last_sign_in_at&.to_s if user.last_sign_in_at
    props[:plan_type] = user.plan_type if user.plan_type
    props[:plan_status] = user.plan_status if user.plan_status
    props[:plan_expires_at] = user.plan_expires_at&.to_s if user.plan_expires_at

    props[:user_id] = user.id&.to_s
    props[:email] = user.email
    email = user.email
    audience_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(email)
    @client.lists.create_list_member_event(
      audience_id,
      subscriber_hash_email,
      {
        event: "Sign In",
        name: "sign_in",
        occurred_at: Time.now.iso8601,
        properties: props || {},
      }
    )
  rescue MailchimpMarketing::ApiError => e
    if e.status == 404
      puts "Subscriber not found for email #{email} in audience #{audience_id}"
      result = record_new_subscriber(user)
      if result
        puts "Successfully added subscriber for email #{email}. Retrying sign-in event."
        retry
      else
        puts "Failed to add subscriber for email #{email}. Cannot record sign-in event."
      end
    end
    nil
  end

  def record_new_subscriber(user, tags: [])
    email = user.email
    merge_fields = {
      FNAME: user.first_name,
      LNAME: user.last_name,
      FULL_NAME: user.display_name,
      USER_TYPE: user.paid_plan? ? "Paid" : "Free",
      PLAN_TYPE: user.plan_type,             # e.g. "Free", "MySpeak+", "Basic", "Pro"
      JOIN_DATE: user.created_at&.to_date&.to_s,
      PARTNERPRO: user.partner_pro? ? "TRUE" : "FALSE",
      # LASTACTIVE: user.last_sign_in_at&.strftime("%m-%d-%Y") || user.current_sign_in_at&.strftime("%m-%d-%Y") || Time.now.beginning_of_year.strftime("%m-%d-%Y"),
      PLANSTATUS: user.plan_status || "N/A",
      USER_ID: user.id.to_s,
      STRIPE_ID: user.stripe_customer_id || "",
      DEMO_USER: user.demo_user? ? "TRUE" : "FALSE",
    }

    list_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(email)
    # Check if subscriber exists
    begin
      result = @client.lists.get_list_member(list_id, subscriber_hash_email)
      if result
        Rails.logger.info("[Mailchimp] Subscriber already exists for email #{email} in audience #{list_id}")
        return result
      end
    rescue MailchimpMarketing::ApiError => e
      if e.status == 404
        Rails.logger.info("[Mailchimp] Subscriber not found for email #{email}. Creating new subscriber.")
      else
        raise e
      end
    end

    body = {
      email_address: email,
      status: "subscribed",
      merge_fields: merge_fields,
    }
    response = @client.lists.set_list_member(list_id, subscriber_hash_email, body)
    # Add tags if provided
    unless tags.blank?
      @client.lists.update_list_member_tags(
        list_id,
        subscriber_hash_email,
        { tags: tags.map { |t| { name: t, status: "active" } } }
      )
    end
    response
  rescue MailchimpMarketing::ApiError => e
    puts "Error recording new subscriber: #{e.message}"
    nil
  end

  def create_audience(name, contact_info, campaign_defaults)
    response = @client.lists.create_list(
      name: name,
      contact: contact_info,
      permission_reminder: "You are receiving this email because you signed up for updates.",
      email_type_option: true,
      campaign_defaults: campaign_defaults,
    )
    response
  rescue MailchimpMarketing::ApiError => e
    puts "Error creating audience: #{e.message}"
    nil
  end
end
