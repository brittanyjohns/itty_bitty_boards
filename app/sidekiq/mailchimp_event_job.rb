class MailchimpEventJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  # Minimum gap between two journey emails to the same person. Journeys are
  # triggered from unrelated seams that can easily coincide — email_signup
  # fires `welcome` and the Stripe webhook fires `subscription_started` minutes
  # later; the nudge crons run at 04:00 and 04:30 — and nothing upstream knows
  # what else that user is about to receive. This job is the single seam every
  # journey trigger passes through, so the gap is enforced here rather than in
  # each caller.
  MIN_GAP_DEFAULT_HOURS = 4

  # A throttled trigger is re-enqueued, not dropped, so the email still arrives
  # — just later. Bounded so a user who qualifies for many journeys at once
  # can't be deferred indefinitely; past the limit the send is abandoned with a
  # loud log (marketing email, so dropping beats spamming). Nudge flags can be
  # cleared with `mailchimp:nudge_flags:clear` if that ever matters.
  MAX_DEFERS = 3

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
      return if defer_for_recent_send(user, key, options)

      result = mailchimp.trigger_journey(user, journey_id: journey[:journey_id], step_id: journey[:step_id])
      # Only a send that actually reached Mailchimp starts the quiet period —
      # a failed trigger must not suppress the next journey.
      record_journey_send(user) if result
    else
      Rails.logger.warn("Unknown Mailchimp event type: #{event_type}")
    end
  end

  private

  def min_gap
    (ENV["MAILCHIMP_JOURNEY_MIN_GAP_HOURS"] || MIN_GAP_DEFAULT_HOURS).to_i.hours
  end

  def throttle_key(user_id)
    "mailchimp:journey:last_sent:#{user_id}"
  end

  # Returns true when this trigger was pushed out to a later time (caller
  # returns without sending). Reads through Rails.cache, whose production
  # error_handler is fail-open: a Redis blip returns nil, so the worst case is
  # sending on time rather than silently swallowing the email.
  def defer_for_recent_send(user, key, options)
    last_sent = Rails.cache.read(throttle_key(user.id))
    return false if last_sent.blank?

    elapsed = Time.current - Time.at(last_sent.to_i).utc
    remaining = min_gap - elapsed
    return false if remaining <= 0

    defers = (options["defers"] || options[:defers] || 0).to_i + 1
    if defers > MAX_DEFERS
      Rails.logger.warn(
        "[Mailchimp] Dropping journey '#{key}' for user #{user.id}: deferred #{MAX_DEFERS} times " \
        "and they're still inside the #{min_gap.inspect} quiet period"
      )
      return true
    end

    # Jitter so a batch deferred by the same run doesn't all land together at
    # the exact moment the quiet period expires.
    delay = remaining + rand(0..900).seconds
    self.class.perform_in(delay, user.id, "journey", options.merge("defers" => defers))
    Rails.logger.info(
      "[Mailchimp] Journey '#{key}' for user #{user.id} is inside the quiet period; " \
      "deferred #{delay.to_i / 60}min (attempt #{defers}/#{MAX_DEFERS})"
    )
    true
  end

  def record_journey_send(user)
    Rails.cache.write(throttle_key(user.id), Time.current.to_i, expires_in: min_gap)
  end
end
