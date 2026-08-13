# frozen_string_literal: true

# Ages out the `past_due` grace state.
#
# Background: `past_due` is deliberately excluded from every other downgrade
# path — it is not in User::UNPAID_STATUSES (so `paid_plan?` stays true and
# `reconcile_stranded_plan!` no-ops on sign-in) and not in the webhook's
# TRIAL_LAPSED_STATUSES, because a real payer's failed renewal belongs in
# Stripe dunning, not in an instant downgrade. The gap that left: nothing
# ever ENDED the grace. When the terminal `customer.subscription.deleted` /
# `unpaid` event never lands — dunning configured to leave the subscription
# past_due, or a missed webhook — the account keeps paid limits forever.
#
# This job closes that hole without touching the dunning window itself:
# past_due for longer than PAST_DUE_GRACE_DAYS (default 30) drops to Free
# through Billing::PlanTransitions.apply_free_plan, so data is retained
# (over-limit boards go read-only, over-limit communicators enter fallback,
# free credits are granted, an editable board is pinned).
#
# Two rails matter here:
#   1. Never downgrade blind. If the account still has a Stripe subscription,
#      the job asks Stripe for its real status first: active/trialing means our
#      recovery webhook was missed, so it heals the user back to `active`
#      instead. A Stripe error skips the user entirely — an unreachable API is
#      not evidence that someone stopped paying.
#   2. Rows that went past_due before the stamp existed get stamped on first
#      sweep and downgrade one grace window later, rather than being
#      mass-downgraded off a guessed date.
class DowngradePastDueJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 2

  DEFAULT_GRACE_DAYS = 30

  # plan_types with nothing to downgrade. basic_trial is owned by
  # DowngradeSoftTrialJob; free is already the floor.
  SKIPPED_PLAN_TYPES = %w[free basic_trial].freeze

  # Stripe statuses that mean the subscription recovered and our `active`
  # webhook was missed.
  STRIPE_ACTIVE_STATUSES = %w[active trialing].freeze

  def perform
    stamped = 0
    downgraded = 0
    recovered = 0
    skipped = 0

    past_due_users.find_each do |user|
      next if user.admin?

      since = user.past_due_since
      if since.nil?
        user.stamp_past_due!
        stamped += 1
        Rails.logger.info "DowngradePastDueJob: stamped legacy past_due user=#{user.id} (grace starts now)"
        next
      end

      next if since > grace_days.days.ago

      case stripe_status(user)
      when :active
        heal_to_active!(user)
        recovered += 1
      when :unknown
        skipped += 1
      else
        downgrade!(user)
        downgraded += 1
      end
    rescue => e
      Rails.logger.error "DowngradePastDueJob: failed for user #{user&.id} - #{e.class} #{e.message}"
    end

    Rails.logger.info "DowngradePastDueJob: downgraded=#{downgraded} recovered=#{recovered} " \
                      "stamped=#{stamped} skipped=#{skipped} grace_days=#{grace_days}"
  end

  private

  def grace_days
    @grace_days ||= begin
      configured = ENV["PAST_DUE_GRACE_DAYS"].to_i
      configured.positive? ? configured : DEFAULT_GRACE_DAYS
    end
  end

  def past_due_users
    User
      .where(plan_status: "past_due")
      .where.not(plan_type: SKIPPED_PLAN_TYPES)
      .where.not(plan_type: [nil, ""])
  end

  # :active when Stripe says the subscription recovered, :unknown when Stripe
  # can't answer (never downgrade on that), :lapsed otherwise — including when
  # there's no subscription left to check.
  def stripe_status(user)
    return :lapsed if user.stripe_subscription_id.blank?

    subscription = Stripe::Subscription.retrieve(user.stripe_subscription_id)
    STRIPE_ACTIVE_STATUSES.include?(subscription.status) ? :active : :lapsed
  rescue Stripe::InvalidRequestError => e
    # A subscription Stripe no longer knows about is gone, not unreachable.
    Rails.logger.info "DowngradePastDueJob: user=#{user.id} subscription missing at Stripe (#{e.message})"
    :lapsed
  rescue => e
    Rails.logger.error "DowngradePastDueJob: Stripe lookup failed for user=#{user.id} - #{e.class} #{e.message}"
    :unknown
  end

  # The subscription is paying again and we missed the webhook. Clearing the
  # status drops the stamp via User#track_past_due_transition.
  def heal_to_active!(user)
    user.update!(plan_status: "active")
    Rails.logger.info "DowngradePastDueJob: user=#{user.id} still active at Stripe -> healed to active"
  end

  def downgrade!(user)
    previous_plan = user.plan_type
    Billing::PlanTransitions.apply_free_plan(user, "canceled")
    UserMailer.subscription_canceled_email(user).deliver_later
    Rails.logger.info "DowngradePastDueJob: user=#{user.id} #{previous_plan} -> free " \
                      "(past_due beyond #{grace_days}d), data retained"
  end
end
