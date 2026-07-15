# Daily expiry enforcer for time-boxed entitlements keyed on `plan_expires_at`.
#
# Background: `plan_expires_at` was written (by 5-Year license purchases and, in
# the past, partner_pro signup) but NO job ever read it to actually enforce the
# expiry — a licensee would keep paid features forever. This job closes that
# hole. It is generic on `plan_expires_at` but deliberately scoped to the
# plan types whose expiry it OWNS:
#
#   - basic_5yr / pro_5yr — one-time 5-Year licenses. Expiry drops them to Free
#     (retaining all data) and offers a renewal ~60 days out.
#
# Intentionally NOT enforced here (scoped out of ENFORCED_PLAN_TYPES):
#   - partner_pro — expiry is owned by the Stripe no-card reverse-trial cancel
#     flow (trial lapses -> customer.subscription.deleted -> lands on a free
#     clinician account; see API::WebhooksController#land_partner_on_clinician!).
#   - clinician  — a granted plan that never expires.
# The query scopes to ENFORCED_PLAN_TYPES so those are untouched; the structure
# leaves room for other plan types to opt in later.
#
# Two passes per eligible user (idempotent, batch-safe):
#   1. RENEWAL pass — a license within LICENSE_RENEWAL_NOTICE_LEAD_DAYS (default
#      60) of its expiry gets license_renewal_offer_email once, flagged
#      settings["renewal_notice_sent_at"].
#   2. EXPIRY pass — a license past plan_expires_at is routed through
#      Billing::PlanTransitions.apply_free_plan (data retained; over-limit
#      boards go read-only, over-limit communicators enter fallback, free
#      credits granted, an editable board pinned) and gets license_ended_email.
#      apply_free_plan resets plan_type to "free", so the user drops out of
#      ENFORCED_PLAN_TYPES and a rerun is a no-op.
class PlanExpiryJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  # Plan types whose plan_expires_at this job enforces. Keep partner_pro and
  # clinician OUT — see the header.
  ENFORCED_PLAN_TYPES = %w[basic_5yr pro_5yr].freeze

  RENEWAL_NOTICE_FLAG = "renewal_notice_sent_at".freeze

  def perform
    now = Time.current
    downgraded = 0
    notified = 0

    expiring_users(now).find_each do |user|
      next if user.respond_to?(:admin?) && user.admin?

      if expired?(user, now)
        downgrade_expired!(user)
        downgraded += 1
      elsif due_for_renewal_notice?(user, now)
        send_renewal_notice!(user)
        notified += 1
      end
    rescue => e
      Rails.logger.error "PlanExpiryJob: failed for user #{user&.id} - #{e.class} #{e.message}"
    end

    Rails.logger.info "PlanExpiryJob: downgraded=#{downgraded} renewal_notices=#{notified}"
  end

  private

  def renewal_lead_days
    (ENV["LICENSE_RENEWAL_NOTICE_LEAD_DAYS"] || 60).to_i
  end

  # Enforced-plan users with an expiry that's either already passed OR within the
  # renewal-notice lead window. One query feeds both passes.
  def expiring_users(now)
    User
      .where(plan_type: ENFORCED_PLAN_TYPES)
      .where.not(plan_expires_at: nil)
      .where("plan_expires_at <= ?", now + renewal_lead_days.days)
  end

  def expired?(user, now)
    user.plan_expires_at.present? && user.plan_expires_at <= now
  end

  def due_for_renewal_notice?(user, now)
    return false if user.plan_expires_at.nil?
    return false if user.plan_expires_at <= now # handled by the expiry pass
    !renewal_notice_sent?(user)
  end

  def renewal_notice_sent?(user)
    user.settings.is_a?(Hash) && user.settings[RENEWAL_NOTICE_FLAG].present?
  end

  def send_renewal_notice!(user)
    UserMailer.license_renewal_offer_email(user).deliver_later
    user.settings = (user.settings || {}).merge(RENEWAL_NOTICE_FLAG => Time.current.iso8601)
    user.save!
    Rails.logger.info "PlanExpiryJob: renewal notice queued user=#{user.id} plan=#{user.plan_type}"
  end

  # Drop to Free with data retained. apply_free_plan handles the read-only board
  # lock, communicator fallback, editable-board pin, and free credit grant.
  def downgrade_expired!(user)
    previous_plan = user.plan_type
    Billing::PlanTransitions.apply_free_plan(user, "canceled")
    UserMailer.license_ended_email(user).deliver_later
    Rails.logger.info "PlanExpiryJob: user=#{user.id} #{previous_plan} -> free (license expired), data retained"
  end
end
