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
#
# The same two facts are also written to `mail_deliveries` (#824), because a log
# line only answers the question for whoever can reach the box — and the person
# who has to trust "we'll email you as soon as it's approved" is looking at the
# admin dashboard.
class MailDeliveryObserver
  def self.delivered_email(message)
    # Mail informs observers even when delivery was suppressed — an interceptor
    # (StagingMailInterceptor / E2eMailInterceptor) clears `perform_deliveries`
    # rather than raising, and those interceptors log their own drop. Logging
    # "delivered" there would be a lie in exactly the place this line is read.
    unless message.perform_deliveries && ActionMailer::Base.perform_deliveries
      # Recorded rather than skipped: on staging EVERY message lands here, and
      # "suppressed" is the one state the logs left indistinguishable from
      # "never attempted" — which is exactly the ambiguity #820 was about.
      MailDelivery.record(status: MailDelivery::SUPPRESSED, message: message, reason: suppression_reason(message))
      return
    end

    Rails.logger.info(
      "[mail] delivered to=#{Array(message.to).join(",")} " \
      "from=#{Array(message.from).join(",")} " \
      "subject=#{message.subject.inspect} " \
      "message_id=#{message.message_id.inspect} " \
      "transport=#{ActionMailer::Base.delivery_method}"
    )
    MailDelivery.record(status: MailDelivery::DELIVERED, message: message)
  rescue StandardError => e
    # Observability must never break a send that already succeeded.
    Rails.logger.warn("[mail] observer failed: #{e.class}: #{e.message}")
  end

  # Best-effort attribution for a drop. The interceptors clear
  # `perform_deliveries` without saying why, so this re-derives it from the
  # same conditions they used rather than having them report it — an
  # interceptor that stops setting a reason would otherwise silently blank it.
  def self.suppression_reason(message)
    return "e2e_recipient" if Array(message.to).any? { |a| a.to_s.match?(E2eMailInterceptor::E2E_RECIPIENT) }
    return "staging" if AppEnv.staging?
    return "perform_deliveries_disabled" unless ActionMailer::Base.perform_deliveries

    "unknown"
  rescue StandardError
    "unknown"
  end
end

ActionMailer::Base.register_observer(MailDeliveryObserver)
