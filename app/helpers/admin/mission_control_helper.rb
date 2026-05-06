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
  end
end
