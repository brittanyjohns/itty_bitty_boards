# Logs one structured line per message the app hands to the transport.
#
# Why this exists: the app had no signal either way about what happened to a
# send. The first clinician applicant with an address outside speakanyway.com
# received none of four transactional emails while an intra-domain control
# account received all of them in the same minute (#820), and nothing in the
# app — logs, `settings.welcome_email_sent`, Sidekiq — could distinguish "never
# sent", "sent and rejected", or "accepted by Gmail and dropped downstream".
#
# An observer fires only AFTER a successful hand-off, so a line here means the
# transport accepted the message; a missing line means the app never sent it.
# The Message-ID is the field that makes the difference actionable: it is the
# key a Google Workspace Email Log Search takes, which is the only place the
# accepted-then-dropped case is visible. Delivery FAILURES are the other half
# and are logged by ApplicationMailer's rescue_from.
#
# Recipients are logged because an admin diagnosing a missing email needs to
# know which address the app actually used; no body or subject-line PII beyond
# what a mail log already carries is emitted.
class MailDeliveryObserver
  def self.delivered_email(message)
    # Mail informs observers even when delivery was suppressed — an interceptor
    # (StagingMailInterceptor / E2eMailInterceptor) clears `perform_deliveries`
    # rather than raising, and those interceptors log their own drop. Logging
    # "delivered" there would be a lie in exactly the place this line is read.
    return unless message.perform_deliveries && ActionMailer::Base.perform_deliveries

    Rails.logger.info(
      "[mail] delivered to=#{Array(message.to).join(",")} " \
      "from=#{Array(message.from).join(",")} " \
      "subject=#{message.subject.inspect} " \
      "message_id=#{message.message_id.inspect} " \
      "transport=#{ActionMailer::Base.delivery_method}"
    )
  rescue StandardError => e
    # Observability must never break a send that already succeeded.
    Rails.logger.warn("[mail] observer failed: #{e.class}: #{e.message}")
  end
end

ActionMailer::Base.register_observer(MailDeliveryObserver)
