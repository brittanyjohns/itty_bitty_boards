require "MailchimpMarketing"

# mailchimp = MailchimpMarketing::Client.new
# mailchimp.set_config({
#   :api_key => API_KEY,
#   :server => "us2",
# })

# event = {
#   name: "SpeakAnyWay AAC Users",
# }

# footer_contact_info = {
#   company: "SpeakAnyWay LLC",
#   address1: "",
#   city: "Lagrange",
#   state: "OH",
#   zip: "44050",
#   country: "US",
# }

# campaign_defaults = {
#   from_name: "SpeakAnyWay Team",
#   from_email: "brittany@speakanyway.com",
#   subject: "Welcome to SpeakAnyWay!",
#   language: "EN_US",
# }

# response = mailchimp.lists.create_list(
#   name: event[:name],
#   contact: footer_contact_info,
#   permission_reminder: "You are receiving this email because you signed up for updates.",
#   email_type_option: true,
#   campaign_defaults: campaign_defaults,
# )

# pp response
# puts ""
# puts "Successfully created an audience. The audience id is #{response["id"]}"

class MailchimpService
  def initialize(audience_id = nil)
    @audience_id = audience_id || ENV["MAILCHIMP_AUDIENCE_ID"]
    @client = MailchimpMarketing::Client.new
    @client.set_config({
      api_key: ENV["MAILCHIMP_API_KEY"],
      server: ENV["MAILCHIMP_SERVER_PREFIX"],
    })
  end

  def audience_id
    @audience_id
  end

  def record_new_subscriber(email, merge_fields = {}, tags = [])
    if audience_id.nil?
      puts "Error: audience_id is not set."
      return nil
    end
    user = User.find_by(email: email)
    if user.nil?
      puts "Error: No user found with email #{email}"
      return nil
    end

    required_merge_fields = {
      FNAME: user.first_name,
      LNAME: user.last_name,
      FULL_NAME: user.name,
      USER_TYPE: user.paid_plan? ? "Paid" : "Free",
      PLAN_TYPE: user.plan_type,             # e.g. "Free", "MySpeak+", "Basic", "Pro"
      JOIN_DATE: user.created_at&.to_date&.to_s,
    }
    all_merge_fields = required_merge_fields.merge(merge_fields)
    body = {
      email_address: email,
      status: "subscribed",
      merge_fields: all_merge_fields,
    }
    response = @client.lists.add_list_member(audience_id, body)
    # Add tags if provided
    unless tags.empty?
      @client.lists.update_list_member_tags(
        audience_id,
        Digest::MD5.hexdigest(email.downcase),
        { tags: tags.map { |t| { name: t, status: "active" } } }
      )
    end
    response
  rescue MailchimpMarketing::ApiError => e
    puts "Error recording new subscriber: #{e.message}"
    nil
  end

  def add_new_free_subscriber(email)
    merge_fields = {
      PLAN_TIER: "Free",
    }
    tags = ["FreePlan"]
    record_new_subscriber(email, merge_fields, tags)
  end

  def add_new_myspeak_subscriber(email)
    merge_fields = {
      PLAN_TIER: "MySpeak",
    }
    tags = ["MySpeakPlan"]
    record_new_subscriber(email, merge_fields, tags)
  end

  def add_new_basic_subscriber(email)
    merge_fields = {
      PLAN_TIER: "Basic",
    }
    tags = ["BasicPlan"]
    record_new_subscriber(email, merge_fields, tags)
  end

  def add_new_pro_subscriber(email)
    merge_fields = {
      PLAN_TIER: "Pro",
    }
    tags = ["ProPlan"]
    record_new_subscriber(email, merge_fields, tags)
  end

  def add_new_premium_subscriber(email)
    merge_fields = {
      PLAN_TIER: "Premium",
    }
    tags = ["PremiumPlan"]
    record_new_subscriber(email, merge_fields, tags)
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

  def add_subscriber(list_id, email)
    @client.lists.add_list_member(list_id, {
      email_address: email,
      status: "subscribed",
    })
  rescue MailchimpMarketing::ApiError => e
    puts "Error adding subscriber: #{e.message}"
  end
end

mailchimp_service = MailchimpService.new("b7456c33f9")
new_user_email = "brittany+pro@speakanyway.com"
result = mailchimp_service.add_new_pro_subscriber(new_user_email)

if result
  puts "Successfully added new pro subscriber: #{new_user_email}"
  pp result
else
  puts "Failed to add new pro subscriber: #{new_user_email}"
end
