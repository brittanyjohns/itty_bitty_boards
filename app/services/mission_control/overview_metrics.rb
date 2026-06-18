module MissionControl
  class OverviewMetrics
    def self.call = new.call

    def call
      {
        signups_today:        User.non_admin.where(created_at: today).count,
        signups_7d:           User.non_admin.where(created_at: 7.days.ago..).count,
        signups_30d:          User.non_admin.where(created_at: 30.days.ago..).count,
        signups_daily_7d:     signups_daily_7d,
        total_users:          User.non_admin.count,
        active_users_7d:      User.non_admin.where(last_sign_in_at: 7.days.ago..).count,
        active_users_30d:     User.non_admin.where(last_sign_in_at: 30.days.ago..).count,
        trial_users:          User.non_admin.where(plan_status: "trialing").count,
        boards_today:         Board.non_templates.where(created_at: today).count,
        boards_7d:            Board.non_templates.where(created_at: 7.days.ago..).count,
        total_boards:         Board.non_templates.count,
        word_events_today:    WordEvent.where(created_at: today).count,
        word_events_7d:       WordEvent.where(created_at: 7.days.ago..).count,
        communicator_accounts: ChildAccount.where.not(status: "archived").count,
        myspeak_profiles:     Profile.where(profileable_type: "ChildAccount").count,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    # group_by_day buckets in Time.zone (not UTC) and zero-fills missing days,
    # so the chart aligns with the Time.zone-based "today" cards.
    def signups_daily_7d
      User.non_admin
          .group_by_day(:created_at, last: 7)
          .count
          .transform_keys(&:to_s)
    end
  end
end
