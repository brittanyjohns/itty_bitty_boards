class MailchimpEventJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  def perform(user_id, event_type, options = {})
    user = User.find_by(id: user_id)
    return unless user

    mailchimp = MailchimpService.new

    case event_type
    when "sign_in"
      mailchimp.record_signin_event(user, options)
    when "sign_up"
      tags = options[:tags] || []
      mailchimp.record_new_subscriber(user, tags: tags)
    when "journey"
      key = options["journey_key"] || options[:journey_key]
      # Never send lifecycle journey emails to demo/internal accounts
      # (same definition that drives the Mailchimp DEMO_USER merge field).
      # CRM sync (sign_up/sign_in) is intentionally NOT gated — we still
      # want demo contacts in the audience, tagged as demo.
      if user.demo_user?
        Rails.logger.info("[Mailchimp] Skipping journey '#{key}' for demo user #{user_id}")
        return
      end
      unless MailchimpClient.journeys_enabled?
        Rails.logger.info("[Mailchimp] Journeys disabled; skipping '#{key}' for user #{user_id}")
        return
      end
      journey = MailchimpClient.journey(key)
      unless journey
        Rails.logger.warn("[Mailchimp] No journey configured for key '#{key}'; skipping")
        return
      end
      mailchimp.trigger_journey(user, journey_id: journey[:journey_id], step_id: journey[:step_id])
    else
      Rails.logger.warn("Unknown Mailchimp event type: #{event_type}")
    end
  end
end
