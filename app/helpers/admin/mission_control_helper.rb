module Admin
  module MissionControlHelper
    EVENT_BADGE_CLASSES = {
      "user_signed_up"         => "bg-indigo-900/60 text-indigo-300",
      "subscription_started"   => "bg-green-900/60 text-green-300",
      "subscription_canceled"  => "bg-red-900/60 text-red-300",
      "board_generated"        => "bg-blue-900/60 text-blue-300",
      "ai_board_generated"     => "bg-purple-900/60 text-purple-300",
      "ai_generation_failed"   => "bg-red-900/60 text-red-400",
      "myspeak_profile_viewed" => "bg-teal-900/60 text-teal-300",
      "word_event_logged"      => "bg-gray-800 text-gray-400",
    }.freeze

    def event_badge_class(event_type)
      EVENT_BADGE_CLASSES.fetch(event_type, "bg-gray-800 text-gray-400")
    end

    PLAN_BADGE_CLASSES = {
      "pro"         => "bg-purple-900/60 text-purple-300",
      "basic"       => "bg-blue-900/60 text-blue-300",
      "basic_trial" => "bg-teal-900/60 text-teal-300",
      "free"        => "bg-gray-800 text-gray-400",
      "partner_pro" => "bg-green-900/60 text-green-300",
    }.freeze

    def plan_badge_class(user)
      PLAN_BADGE_CLASSES.fetch(user.plan_type.to_s, "bg-gray-800 text-gray-400")
    end

    # settings["signup_platform"] is written by User#record_signup_context! and
    # only ever holds what the signup request declared. Accounts created before
    # that shipped have no key at all — "unknown", not "web", since guessing
    # would quietly inflate the web share of every cohort read off this table.
    SIGNUP_PLATFORM_BADGE_CLASSES = {
      "ios"     => "bg-blue-900/60 text-blue-300",
      "android" => "bg-green-900/60 text-green-300",
      "web"     => "bg-indigo-900/60 text-indigo-300",
    }.freeze

    def signup_platform(user)
      settings = user.settings.is_a?(Hash) ? user.settings : {}
      settings["signup_platform"].presence || "unknown"
    end

    def signup_platform_badge_class(platform)
      SIGNUP_PLATFORM_BADGE_CLASSES.fetch(platform.to_s, "bg-gray-800 text-gray-400")
    end

    # --- Trial state -------------------------------------------------------
    # "Is this account trialing, and when does it end" — the question the admin
    # users table asks. Keyed on plan_status, which is the one field BOTH
    # providers write (Stripe subscription webhooks and RevenueCat alike), plus
    # the legacy `basic_trial` soft-trial cohort, which predates plan_status and
    # so carries none. Partner pilots are trials too and are included here on
    # purpose; their own pilot badge answers a different question (where the
    # 3-month window sits), not whether a trial is running.
    TRIAL_STATE_META = {
      ended:       { label: "Trial ended", badge: "bg-red-900/60 text-red-300" },
      ending_soon: { label: "Ends soon",   badge: "bg-yellow-900/60 text-yellow-300" },
      trialing:    { label: "Trialing",    badge: "bg-teal-900/60 text-teal-300" },
      no_end_date: { label: "Trialing",    badge: "bg-gray-800 text-gray-400" },
    }.freeze

    TRIAL_ENDING_SOON_DAYS = 3

    def trialing?(user)
      user.plan_status.to_s == "trialing" || user.plan_type.to_s == "basic_trial"
    end

    # Returns nil for an account that isn't trialing. Never mutates anything.
    def trial_status(user)
      return nil unless trialing?(user)

      ends_at = trial_end_date(user)
      state =
        if ends_at.nil?               then :no_end_date
        elsif ends_at <= Time.current then :ended
        elsif ends_at <= Time.current + TRIAL_ENDING_SOON_DAYS.days then :ending_soon
        else :trialing
        end

      meta = TRIAL_STATE_META.fetch(state)
      days_left = ends_at ? ((ends_at - Time.current) / 1.day).ceil : nil
      provider = trial_provider_label(user)
      {
        state: state,
        label: meta[:label],
        badge_class: meta[:badge],
        ends_at: ends_at,
        days_left: days_left,
        provider: provider,
        # Only meaningful for a Stripe reverse trial (#264) — a RevenueCat
        # trialist already pays through the store and can't add a card here.
        needs_payment_method: provider == "Stripe" && (settings_hash(user)["has_payment_method"] != true),
        title: trial_title(provider, ends_at, days_left),
      }
    end

    # settings["trial_ends_at"] is what both webhook paths persist (ISO8601);
    # plan_expires_at is the partner-pilot date and the fallback for a trial
    # that predates that key. Parsing is defensive on purpose — one malformed
    # string must not 500 a table rendering every user.
    def trial_end_date(user)
      raw = settings_hash(user)["trial_ends_at"]
      if raw.present?
        begin
          parsed = Time.zone.parse(raw.to_s)
          return parsed if parsed
        rescue ArgumentError, TypeError
          # fall through to the column
        end
      end
      user.plan_expires_at
    end

    PARTNER_PILOT_STATE_META = {
      ended:        { label: "Pilot ended",  badge: "bg-red-900/60 text-red-300" },
      ending_soon:  { label: "Ending soon",  badge: "bg-yellow-900/60 text-yellow-300" },
      active:       { label: "Pilot active", badge: "bg-green-900/60 text-green-300" },
      no_end_date:  { label: "No end date",  badge: "bg-gray-800 text-gray-400" },
    }.freeze

    def partner_pilot?(user)
      user.plan_type.to_s == "partner_pro"
    end

    # Snapshot of where a Partner Pro pilot sits in its 3-month window, for the
    # admin dashboard. Mirrors the categories PartnerPilotEndingJob acts on.
    # Returns nil for non-partners. Never mutates anything.
    def partner_pilot_status(user)
      return nil unless partner_pilot?(user)

      ends_at = user.plan_expires_at
      settings = user.settings.is_a?(Hash) ? user.settings : {}
      lead_days = (ENV["PARTNER_PILOT_REMINDER_LEAD_DAYS"] || 14).to_i

      state =
        if ends_at.nil?               then :no_end_date
        elsif ends_at <= Time.current then :ended
        elsif ends_at <= Time.current + lead_days.days then :ending_soon
        else :active
        end

      meta = PARTNER_PILOT_STATE_META.fetch(state)
      {
        state: state,
        label: meta[:label],
        badge_class: meta[:badge],
        end_date: ends_at,
        days_left: ends_at ? ((ends_at - Time.current) / 1.day).ceil : nil,
        reminded: settings["partner_pilot_ending_notified"] == true,
        expired_flagged: settings["partner_pilot_expired"] == true,
        expired_at: settings["partner_pilot_expired_at"],
      }
    end

    private

    def settings_hash(user)
      user.settings.is_a?(Hash) ? user.settings : {}
    end

    # A Stripe trial always carries a subscription id; a RevenueCat (IAP) trial
    # never does. The legacy soft trial ran through neither.
    def trial_provider_label(user)
      return "Stripe" if user.stripe_subscription_id.present?
      return "RevenueCat" if user.plan_status.to_s == "trialing"

      "soft trial"
    end

    def trial_title(provider, ends_at, days_left)
      parts = [provider == "soft trial" ? "Legacy soft trial" : "#{provider} trial"]
      parts << if ends_at.nil?
                 "no end date recorded"
               elsif ends_at <= Time.current
                 "ended #{ends_at.strftime("%b %-d, %Y")}"
               else
                 "ends #{ends_at.strftime("%b %-d, %Y")} (#{days_left} day#{"s" unless days_left == 1})"
               end
      parts.join(" \u00b7 ")
    end
  end
end
