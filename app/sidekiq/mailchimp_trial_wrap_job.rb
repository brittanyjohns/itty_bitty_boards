# Triggers the Mailchimp "trial_wrap" Customer Journey ~3 days before a
# Stripe trial ends (enqueued from the `customer.subscription.trial_will_end`
# webhook). Personalizes the email by first pushing the contact's merge
# fields — TRIAL_END (formatted date), BOARDS, COMMS — so the journey copy
# can say "you made N boards and M communicators; keep them by continuing."
#
# Soft trials (basic_trial) were retired — every new signup lands on Free —
# so the only trials are Stripe no-card reverse trials (#264), which this
# webhook path covers.
#
# Merge-field tags (create these in the Mailchimp audience, ≤10 chars each):
#   TRIAL_END · BOARDS · COMMS
#
# Partner pilots ride the same Stripe reverse trial, so this same webhook path
# covers them — but they get a DIFFERENT journey (`partner_pilot_wrap`): copy
# that names the $10/mo Partner Pro rate and offers "reply to re-up your partner
# program" instead of the generic "add a card to keep your plan" nudge. Which
# journey fires is chosen by `partner_pro?`; both use the same merge fields.
#
# Self-contained gating (mirrors MailchimpEventJob's journey path) so it
# no-ops cleanly when journeys are disabled or the key isn't configured.
class MailchimpTrialWrapJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  JOURNEY_KEY = "trial_wrap".freeze
  PARTNER_JOURNEY_KEY = "partner_pilot_wrap".freeze

  def perform(user_id, trial_end_epoch = nil)
    user = User.find_by(id: user_id)
    return unless user

    journey_key = user.partner_pro? ? PARTNER_JOURNEY_KEY : JOURNEY_KEY

    unless MailchimpClient.journeys_enabled?
      Rails.logger.info("[Mailchimp] Journeys disabled; skipping #{journey_key} for user #{user_id}")
      return
    end

    journey = MailchimpClient.journey(journey_key)
    unless journey
      Rails.logger.warn("[Mailchimp] No journey configured for '#{journey_key}'; skipping")
      return
    end

    mailchimp = MailchimpService.new
    mailchimp.update_merge_fields(user, {
      "TRIAL_END" => format_trial_end(trial_end_epoch),
      "BOARDS" => user.countable_board_count.to_s,
      "COMMS" => user.communicator_accounts.count.to_s,
    })
    mailchimp.trigger_journey(user, journey_id: journey[:journey_id], step_id: journey[:step_id])
  rescue => e
    Rails.logger.error "MailchimpTrialWrapJob: failed for user #{user_id} - #{e.message}"
  end

  private

  # Stripe sends trial_end as epoch seconds. Render as e.g. "June 20".
  # Falls back to "soon" so the copy reads cleanly if the date is missing.
  def format_trial_end(epoch)
    return "soon" if epoch.blank?

    Time.at(epoch.to_i).utc.strftime("%B %-d")
  rescue StandardError
    "soon"
  end
end
