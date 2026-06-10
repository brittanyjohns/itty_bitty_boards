# Shared helper for enqueuing the Mailchimp "hit_limit" Customer Journey when a
# Free user bumps into the board cap. Included by API::BoardsController and
# API::MenusController — the two create paths gated by a board limit — so both
# surfaces (regular boards and the Menu Board Creator) trigger the same
# re-engagement email.
module MailchimpHitLimitNotifier
  extend ActiveSupport::Concern

  HIT_LIMIT_DEDUPE_TTL = 14.days

  private

  # Enqueue the "hit_limit" journey, deduped per user (Rails.cache) so a user
  # mashing the create button isn't emailed repeatedly.
  #
  # The dedupe key is written ONLY when the journey can actually fire — the user
  # is a Free user, journeys are enabled for this env, AND the hit_limit
  # journey is configured. Without these up-front guards a single no-op (ENV
  # unset, staging/dev) would still stamp the key and silently suppress the
  # email for the full TTL even after the cause was fixed — the bug behind
  # "I hit the limit but never got the email." Mirroring the job's own guards
  # here also avoids enqueuing jobs that would just no-op.
  #
  # NOTE: no `user.demo_user?` guard here while the #306 temporary revert of
  # #297 is in effect (demo accounts receive journey emails for E2E testing).
  # When #297 is restored, re-add `return if user.demo_user?` here so a demo
  # account can't stamp the dedupe key for a journey the job will skip.
  #
  # Guarded end-to-end: any Redis/Sidekiq blip logs a warning rather than
  # 500ing the create request.
  def notify_mailchimp_hit_limit(user)
    return unless user&.plan_type == "free"
    return unless MailchimpClient.journeys_enabled?
    return unless MailchimpClient.journey("hit_limit")

    dedupe_key = "mailchimp:hit_limit:#{user.id}"
    return if Rails.cache.read(dedupe_key)

    MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "hit_limit" })
    Rails.cache.write(dedupe_key, true, expires_in: HIT_LIMIT_DEDUPE_TTL)
  rescue StandardError => e
    Rails.logger.warn("[Mailchimp] hit_limit enqueue failed for user #{user&.id}: #{e.message}")
  end
end
