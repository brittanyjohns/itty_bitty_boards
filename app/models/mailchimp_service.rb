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
        Rails.logger.info("[Mailchimp] Added subscriber for #{email}. Retrying sign-in event.")
        retry
      else
        Rails.logger.error("[Mailchimp] Failed to add subscriber for #{email}. Cannot record sign-in event.")
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
    # Swallowed so a Mailchimp blip can't break signup, but logged at error
    # level with status + detail so a *permanent* config problem (e.g. an
    # audience "required merge field" like ADDRESS rejecting every new-contact
    # upsert with a 400) is visible instead of silently failing every signup
    # sync. Was a bare `puts` that never reached the structured log / tracker.
    Rails.logger.error("[Mailchimp] record_new_subscriber failed for #{email}: #{e.status} #{e.detail || e.message}")
    nil
  end

  # Lightweight sibling of record_new_subscriber for raw email leads (no User
  # object). Upserts a bare email to the audience as "subscribed" with the given
  # tags and minimal merge fields (FNAME from name when present). Used for the
  # anonymous free-board-download lead capture. Reuses the same client / audience
  # id / subscriber_hash patterns as the rest of this service.
  def record_lead(email:, name: nil, tags: [])
    list_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(email)

    merge_fields = {}
    merge_fields[:FNAME] = name if name.present?

    body = {
      email_address: email,
      status_if_new: "subscribed",
      merge_fields: merge_fields,
    }
    response = @client.lists.set_list_member(list_id, subscriber_hash_email, body)

    unless tags.blank?
      @client.lists.update_list_member_tags(
        list_id,
        subscriber_hash_email,
        { tags: tags.map { |t| { name: t, status: "active" } } }
      )
    end

    response
  end

  # Enrol a contact into a Mailchimp Customer Journey via its API-trigger step.
  # Mailchimp then sends the email designed in that journey. The contact must
  # already be an audience member; if Mailchimp 404s we upsert them and retry
  # once (guarded so a misconfigured journey_id can't loop forever).
  def trigger_journey(user, journey_id:, step_id:)
    journeys = customer_journeys_api
    if journeys.nil?
      Rails.logger.error(
        "[Mailchimp] Customer Journeys API unavailable on the client; " \
        "skipping journey #{journey_id}/#{step_id} for #{user.email}"
      )
      return nil
    end

    attempted_subscribe = false
    begin
      journeys.trigger(
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
    rescue NoMethodError => e
      # A NoMethodError here means the gem's journeys accessor/shape changed
      # (the historical `customer_journeys` snake_case bug, which raised on
      # every trigger and piled hundreds of jobs into the Sidekiq dead set).
      # Retrying can't fix a missing method, so swallow it: log loudly and
      # return nil so MailchimpEventJob succeeds instead of exhausting its
      # retries into Dead.
      Rails.logger.error "[Mailchimp] Customer Journeys accessor unavailable for journey #{journey_id}/#{step_id}: #{e.message}"
      nil
    end
  end

  # Resolve the gem's Customer Journeys API regardless of accessor casing. The
  # MailchimpMarketing gem exposes it as camelCase `customerJourneys` (no
  # snake_case alias today); resolving defensively means a future casing change
  # can't silently break, and we never call a method the client doesn't have.
  def customer_journeys_api
    return @client.customerJourneys if @client.respond_to?(:customerJourneys)
    return @client.customer_journeys if @client.respond_to?(:customer_journeys)

    nil
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

  def archive_subscriber(user, reason: "user_requested")
    list_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(user.email)

    update_subscriber_tags(
      user.email,
      ["AccountDeleted", "deleted:#{reason}"],
      []
    )

    @client.lists.update_list_member(
      list_id,
      subscriber_hash_email,
      { status: "unsubscribed" }
    )

    Rails.logger.info("[Mailchimp] Archived subscriber #{user.id} (#{reason})")
    true
  rescue MailchimpMarketing::ApiError => e
    if e.status == 404
      Rails.logger.info("[Mailchimp] Subscriber #{user.id} not found in audience — nothing to archive")
      return true
    end
    Rails.logger.error("[Mailchimp] archive_subscriber failed for user #{user.id}: #{e.message}")
    false
  end

  def delete_subscriber_permanently(user)
    list_id = ENV.fetch("MAILCHIMP_AUDIENCE_ID")
    subscriber_hash_email = subscriber_hash(user.email)

    @client.lists.delete_list_member_permanent(list_id, subscriber_hash_email)
    Rails.logger.info("[Mailchimp] Permanently deleted subscriber #{user.id}")
    true
  rescue MailchimpMarketing::ApiError => e
    if e.status == 404
      Rails.logger.info("[Mailchimp] Subscriber #{user.id} not found — nothing to delete")
      return true
    end
    Rails.logger.error("[Mailchimp] delete_subscriber_permanently failed for user #{user.id}: #{e.message}")
    false
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
