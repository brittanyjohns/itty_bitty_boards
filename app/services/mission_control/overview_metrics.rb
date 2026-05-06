module MissionControl
  class OverviewMetrics
    def self.call = new.call

    def call
      {
        signups_today:        User.non_admin.where(created_at: today).count,
        signups_7d:           User.non_admin.where(created_at: 7.days.ago..).count,
        signups_30d:          User.non_admin.where(created_at: 30.days.ago..).count,
        total_users:          User.non_admin.count,
        boards_today:         Board.non_templates.where(created_at: today).count,
        boards_7d:            Board.non_templates.where(created_at: 7.days.ago..).count,
        total_boards:         Board.non_templates.count,
        word_events_today:    WordEvent.where(created_at: today).count,
        word_events_7d:       WordEvent.where(created_at: 7.days.ago..).count,
        myspeak_profiles:     Profile.where(profileable_type: "ChildAccount").count,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end
  end
end
