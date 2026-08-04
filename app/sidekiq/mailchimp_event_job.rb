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
      unless MailchimpClient.journeys_enabled?
        Rails.logger.info("[Mailchimp] Journeys disabled; skipping '#{key}' for user #{user_id}")
        return
      end
      # Demo/internal accounts (bhannajohns+*, @speakanyway.com) don't get
      # journey email — they'd otherwise pull real campaign sends and skew the
      # journey's open/click stats. CRM sync is deliberately NOT gated: demo
      # contacts stay in the audience, tagged via the DEMO_USER merge field.
      # Set MAILCHIMP_JOURNEYS_ALLOW_DEMO=true to end-to-end test a journey
      # with a demo account instead of reverting this guard.
      if user.demo_user? && ENV["MAILCHIMP_JOURNEYS_ALLOW_DEMO"] != "true"
        Rails.logger.info("[Mailchimp] Demo account; skipping journey '#{key}' for user #{user_id}")
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
