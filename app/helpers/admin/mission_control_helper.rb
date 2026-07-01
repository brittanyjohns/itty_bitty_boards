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
  end
end
