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
      JOIN_DATE: user.created_at&.to_date&.to_s,
      USER_ID: user.id.to_s,
      STRIPE_ID: user.stripe_customer_id || "",
      DEMO_USER: user.demo_user? ? "TRUE" : "FALSE",
    }
    # plan_type = user.plan_type || "free"
    # tags << plan_type.capitalize
    # role = user.role || "user"
    # tags << role.capitalize
    plan_type = user.plan_type || "free"
    tags << "#{plan_type&.camelcase(:upper)}Plan" || "FreePlan"

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

  # Enrol a contact into a Mailchimp Customer Journey via its API-trigger step.
  # Mailchimp then sends the email designed in that journey. The contact must
  # already be an audience member; if Mailchimp 404s we upsert them and retry
  # once (guarded so a misconfigured journey_id can't loop forever).
  def trigger_journey(user, journey_id:, step_id:)
    attempted_subscribe = false
    begin
      # NOTE: the MailchimpMarketing gem exposes this API as `customerJourneys`
      # (camelCase) — there is no snake_case `customer_journeys` accessor, so
      # using it raises NoMethodError at runtime.
      @client.customerJourneys.trigger(
        journey_id,
        step_id,
        { email_address: user.email }
      )
    rescue MailchimpMarketing::ApiError => e
      if e.status == 404 && !attempted_subscribe
        attempted_subscribe = true
        retry if record_new_subscriber(user)
      end
      Rails.logger.error "[Mailchimp] Failed to trigger journey #{journey_id}/#{step_id}: #{e.message}"
      nil
    end
  end

  # Upsert merge fields on a contact (e.g. trial-wrap personalization:
  # TRIAL_END / BOARDS / COMMS). Uses set_list_member so it creates the
  # contact if missing (status_if_new: subscribed) and updates merge fields
  # if present. Guarded — a Mailchimp blip logs and returns nil rather than
  # raising into the caller (which is usually a journey-trigger job).
  def update_merge_fields(user, fields)
    list_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(user.email)
    @client.lists.set_list_member(
      list_id,
      subscriber_hash_email,
      {
        email_address: user.email,
        status_if_new: "subscribed",
        merge_fields: fields,
      }
    )
  rescue MailchimpMarketing::ApiError => e
    Rails.logger.warn "[Mailchimp] update_merge_fields failed for #{user.email}: #{e.message}"
    nil
  end

  def update_subscriber_tags(email, tags_to_add = [], tags_to_remove = [])
    list_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(email)
    body = {
      tags: [],
    }
    tags_to_add.each do |tag|
      if tag.nil? || tag.strip.empty?
        next
      end
      Rails.logger.info "Adding tag: #{tag}"

      body[:tags] << { name: tag, status: "active" }
    end
    tags_to_remove.each do |tag|
      Rails.logger.info "Removing tag: #{tag}"
      body[:tags] << { name: tag, status: "inactive" }
    end
    response = @client.lists.update_list_member_tags(
      list_id,
      subscriber_hash_email,
      body
    )
    response
  rescue MailchimpMarketing::ApiError => e
    Rails.logger.error "Error updating subscriber tags: #{e.message}"
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
    Rails.logger.error "Error creating audience: #{e.message}"
    nil
  end
end
