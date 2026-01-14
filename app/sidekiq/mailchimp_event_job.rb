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
    else
      Rails.logger.warn("Unknown Mailchimp event type: #{event_type}")
    end
  end
end
