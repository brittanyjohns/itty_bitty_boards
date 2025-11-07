# app/sidekiq/mailchimp_upsert_subscriber_job.rb
class MailchimpUpsertSubscriberJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true
  def perform(user_id, opts = {})
    user = User.find(user_id)
    plan_type = user.plan_type&.downcase || "free"

    mailchimp_service = MailchimpService.new

    if plan_type.include? "free"
      mailchimp_service.record_new_subscriber(user, tags: ["FreePlan"])
    elsif plan_type.include? "myspeak"
      mailchimp_service.record_new_subscriber(user, tags: ["MySpeakPlan"])
    elsif plan_type.include? "basic"
      mailchimp_service.record_new_subscriber(user, tags: ["BasicPlan"])
    elsif plan_type.include? "pro"
      mailchimp_service.record_new_subscriber(user, tags: ["ProPlan"])
    elsif plan_type.include? "premium"
      mailchimp_service.record_new_subscriber(user, tags: ["PremiumPlan"])
    else
      Rails.logger.warn("[Mailchimp] Unknown plan type '#{plan_type}' for user #{user.id}")
      mailchimp_service.record_new_subscriber(user, tags: ["UnknownPlan"])
    end

    # Optional: fire a custom event for Journeys (“Upgraded”, “Cancelled”, etc.)
    if (event_name = opts[:event]).present?
      client.lists.create_list_member_event(
        audience_id,
        subscriber_hash,
        { name: event_name, properties: opts[:event_properties] || {} }
      )
    end
  rescue MailchimpMarketing::ApiError => e
    # Surface useful context in logs; Job retry handles transient errors.
    Rails.logger.error("[Mailchimp] API error: #{e.status} #{e.detail || e.message}")
    raise
  end
end
