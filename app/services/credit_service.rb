# frozen_string_literal: true

# Source of truth for AI feature gating.
#
# Spend order: plan credits first (they expire), then topup credits (don't expire).
# Grants are idempotent on stripe_event_id when provided.
class CreditService
  class InsufficientCredits < StandardError
    attr_reader :needed, :balance, :feature_key

    def initialize(needed:, balance:, feature_key:)
      @needed = needed
      @balance = balance
      @feature_key = feature_key
      super("Insufficient credits for #{feature_key}: needed #{needed}, balance #{balance}")
    end
  end

  # Per-feature credit cost. Server-side only; clients never pick the cost.
  # Tuning these is a config change, not a schema change.
  FEATURE_COSTS = {
    "word_suggestion" => 1,
    "board_format" => 2,
    "image_edit" => 5,
    "image_variation" => 3,
    "image_generation" => 3,
    "screenshot_import" => 3,
    "scenario_create" => 5,
    "menu_create" => 5,
    # Legacy single-bucket key (during shadow mode / migration)
    "ai_action" => 1,
  }.freeze

  # Default monthly grant by plan_type. Stripe Price metadata overrides at grant time.
  PLAN_MONTHLY_CREDITS = {
    "free" => 5,
    "basic_trial" => 400, # Soft 14-day Basic trial set by User#set_soft_trial_plan
    "basic" => 400,
    "pro" => 1500,
    "premium" => 1500,
    "partner_pro" => 1500,
    "vendor" => 1500,
  }.freeze

  # How long an initial grant lasts when the user is NOT on a Stripe-driven
  # billing cycle (no subscription yet, or canceled). Stripe-driven grants
  # use `subscription.current_period_end` / `trial_end` instead.
  INITIAL_PERIOD_DAYS = {
    "basic_trial" => 14, # matches User#TRAIL_PERIOD (sic)
  }.freeze
  DEFAULT_INITIAL_PERIOD_DAYS = 30

  # Floor for `grant_plan!` period_end. Any caller passing a past/today
  # `period_end` gets clamped forward to this window. Prevents the
  # "granted and expired same day" bug (issue #110 and follow-ups) where
  # ExpirePlanCreditsJob would sweep the new grant to 0 within the hour.
  MIN_GRANT_WINDOW = 1.day

  # Ceiling for `grant_plan!` period_end. Plan credits are a MONTHLY bucket
  # (PLAN_MONTHLY_CREDITS), so a grant must never reset further out than ~1
  # month — otherwise a YEARLY subscriber would receive a single month's
  # allowance stretched across the whole year. Monthly subs (period ≤ 31d) are
  # never capped, so their invoice/RENEWAL cadence still drives the reset.
  # Yearly subs land here: their reset is pulled back to ~1 month and the
  # monthly re-grant is handled by RefreshFreeTierCreditsJob (which now covers
  # yearly Stripe subs and all RevenueCat subs).
  MAX_GRANT_WINDOW = 35.days

  class << self
    def cost_for(feature_key)
      FEATURE_COSTS[feature_key.to_s] || 1
    end

    def monthly_credits_for(plan_type)
      PLAN_MONTHLY_CREDITS[plan_type.to_s] || PLAN_MONTHLY_CREDITS["free"]
    end

    def initial_period_end_for(plan_type, from: Time.current)
      days = INITIAL_PERIOD_DAYS[plan_type.to_s] || DEFAULT_INITIAL_PERIOD_DAYS
      from + days.days
    end

    # Grant the user's tier's monthly allowance — for users who haven't gone
    # through Stripe yet (free, soft-trial). Idempotent: returns the existing
    # grant when the user already has any `plan_grant` row, so this is safe
    # to call from after_create callbacks, sign-in hooks, etc.
    def ensure_initial_grant!(user)
      return nil if user.respond_to?(:admin?) && user.admin?

      existing = user.credit_transactions.where(kind: "plan_grant").order(created_at: :asc).first
      return existing if existing

      plan_type = user.plan_type.presence || "free"
      amount = monthly_credits_for(plan_type)
      return nil if amount <= 0

      grant_plan!(
        user,
        amount: amount,
        period_end: initial_period_end_for(plan_type),
        metadata: { source: "initial_grant", plan_type: plan_type },
      )
    rescue => e
      Rails.logger.error "[CreditService] ensure_initial_grant! failed for user=#{user&.id}: #{e.class} #{e.message}"
      nil
    end

    def balance(user)
      {
        plan: user.plan_credits_balance.to_i,
        topup: user.topup_credits_balance.to_i,
        total: user.plan_credits_balance.to_i + user.topup_credits_balance.to_i,
        reset_at: user.plan_credits_reset_at,
      }
    end

    # Spend credits for an AI feature. Plan credits drained first, then top-up.
    # Returns a CreditTransaction. Raises InsufficientCredits if not enough.
    def spend!(user, feature_key:, amount: nil, metadata: {})
      amount ||= cost_for(feature_key)
      raise ArgumentError, "amount must be positive" if amount <= 0

      ActiveRecord::Base.transaction do
        user.lock!
        total = user.plan_credits_balance.to_i + user.topup_credits_balance.to_i
        if total < amount
          raise InsufficientCredits.new(needed: amount, balance: total, feature_key: feature_key.to_s)
        end

        from_plan = [user.plan_credits_balance.to_i, amount].min
        from_topup = amount - from_plan

        user.update_columns(
          plan_credits_balance: user.plan_credits_balance.to_i - from_plan,
          topup_credits_balance: user.topup_credits_balance.to_i - from_topup,
        )

        source = from_plan >= from_topup ? "plan" : "topup"
        CreditTransaction.create!(
          user: user,
          amount: -amount,
          kind: "spend",
          source: source,
          feature_key: feature_key.to_s,
          metadata: metadata.merge(from_plan: from_plan, from_topup: from_topup),
        )
      end
    end

    # Idempotent on stripe_event_id. period_end becomes the expires_at for the grant.
    # Resets the user's plan_credits_balance to `amount` (full reset, not additive)
    # so leftover plan credits from the previous period do not roll over.
    def grant_plan!(user, amount:, period_end:, stripe_event_id: nil, stripe_price_id: nil, metadata: {})
      raise ArgumentError, "amount must be positive" if amount <= 0

      min_period_end = Time.current + MIN_GRANT_WINDOW
      if period_end.blank? || period_end < min_period_end
        Rails.logger.warn(
          "[CreditService] grant_plan! period_end #{period_end.inspect} too soon; " \
          "clamping to #{min_period_end} for user=#{user.id} metadata=#{metadata.inspect}"
        )
        period_end = min_period_end
      end

      # Cap the window so a yearly billing period can't stretch one month's
      # allowance across a year. RefreshFreeTierCreditsJob re-grants monthly.
      max_period_end = Time.current + MAX_GRANT_WINDOW
      period_end = max_period_end if period_end > max_period_end

      ActiveRecord::Base.transaction do
        if stripe_event_id.present? && CreditTransaction.exists?(stripe_event_id: stripe_event_id)
          return CreditTransaction.find_by(stripe_event_id: stripe_event_id)
        end

        user.lock!
        # Expire any leftover plan credits first (ledger trace)
        if user.plan_credits_balance.to_i.positive?
          CreditTransaction.create!(
            user: user,
            amount: -user.plan_credits_balance.to_i,
            kind: "expire",
            source: "plan",
            metadata: { reason: "superseded_by_plan_grant" },
          )
        end

        user.update_columns(
          plan_credits_balance: amount,
          plan_credits_reset_at: period_end,
        )

        CreditTransaction.create!(
          user: user,
          amount: amount,
          kind: "plan_grant",
          source: "plan",
          stripe_event_id: stripe_event_id,
          stripe_price_id: stripe_price_id,
          expires_at: period_end,
          metadata: metadata,
        )
      end
    rescue ActiveRecord::RecordNotUnique
      CreditTransaction.find_by(stripe_event_id: stripe_event_id)
    end

    # Idempotent on stripe_event_id. Additive to topup_credits_balance; no expiration by default.
    def grant_topup!(user, amount:, stripe_event_id: nil, stripe_price_id: nil, expires_at: nil, metadata: {})
      raise ArgumentError, "amount must be positive" if amount <= 0

      ActiveRecord::Base.transaction do
        if stripe_event_id.present? && CreditTransaction.exists?(stripe_event_id: stripe_event_id)
          return CreditTransaction.find_by(stripe_event_id: stripe_event_id)
        end

        user.lock!
        user.update_columns(
          topup_credits_balance: user.topup_credits_balance.to_i + amount,
        )

        CreditTransaction.create!(
          user: user,
          amount: amount,
          kind: "topup_purchase",
          source: "topup",
          stripe_event_id: stripe_event_id,
          stripe_price_id: stripe_price_id,
          expires_at: expires_at,
          metadata: metadata,
        )
      end
    rescue ActiveRecord::RecordNotUnique
      CreditTransaction.find_by(stripe_event_id: stripe_event_id)
    end

    # Zero out plan credits and write an "expire" ledger row.
    # Top-up balance is untouched.
    def expire_plan_credits!(user, reason: "period_ended")
      ActiveRecord::Base.transaction do
        user.lock!
        remaining = user.plan_credits_balance.to_i
        return nil if remaining <= 0

        user.update_columns(plan_credits_balance: 0)
        CreditTransaction.create!(
          user: user,
          amount: -remaining,
          kind: "expire",
          source: "plan",
          metadata: { reason: reason },
        )
      end
    end

    # Refund credits that were already spent (e.g. AI call failed downstream).
    # Returns to the same source they came from.
    def refund!(user, amount:, feature_key:, source: "plan", metadata: {})
      raise ArgumentError, "amount must be positive" if amount <= 0
      raise ArgumentError, "invalid source" unless %w[plan topup].include?(source)

      ActiveRecord::Base.transaction do
        user.lock!
        if source == "plan"
          user.update_columns(plan_credits_balance: user.plan_credits_balance.to_i + amount)
        else
          user.update_columns(topup_credits_balance: user.topup_credits_balance.to_i + amount)
        end

        CreditTransaction.create!(
          user: user,
          amount: amount,
          kind: "refund",
          source: source,
          feature_key: feature_key.to_s,
          metadata: metadata,
        )
      end
    end

    # Shadow-mode: try to spend, but never raise. Returns true if it would have succeeded.
    # Used during Phase 1 rollout for telemetry.
    def shadow_spend(user, feature_key:, amount: nil, metadata: {})
      spend!(user, feature_key: feature_key, amount: amount, metadata: metadata)
      true
    rescue InsufficientCredits => e
      Rails.logger.warn "[CreditService][shadow] would have blocked user=#{user.id} feature=#{e.feature_key} needed=#{e.needed} balance=#{e.balance}"
      false
    rescue => e
      Rails.logger.error "[CreditService][shadow] error user=#{user.id} feature=#{feature_key}: #{e.class} #{e.message}"
      false
    end
  end
end
