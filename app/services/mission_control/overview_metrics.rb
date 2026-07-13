module MissionControl
  class OverviewMetrics
    include ExcludesDemo

    def self.call = new.call

    def call
      {
        signups_today:        real_users.where(created_at: today).count,
        signups_7d:           real_users.where(created_at: 7.days.ago..).count,
        signups_30d:          real_users.where(created_at: 30.days.ago..).count,
        signups_daily_7d:     signups_daily_7d,
        total_users:          real_users.count,
        active_users_7d:      real_users.where(last_sign_in_at: 7.days.ago..).count,
        active_users_30d:     real_users.where(last_sign_in_at: 30.days.ago..).count,
        trial_users:          real_users.where(plan_status: "trialing").count,
        boards_today:         real_boards.where(created_at: today).count,
        boards_7d:            real_boards.where(created_at: 7.days.ago..).count,
        total_boards:         real_boards.count,
        word_events_today:    without_demo(WordEvent.where(created_at: today)).count,
        word_events_7d:       without_demo(WordEvent.where(created_at: 7.days.ago..)).count,
        communicator_accounts: real_communicators.count,
        myspeak_profiles:     Profile.where(profileable_type: "ChildAccount",
                                            profileable_id: without_demo(ChildAccount.all).select(:id)).count,
      }
    end

    private

    # Real = the accounts the metrics are about: not admins, not demo/test.
    def real_users
      User.non_admin.non_demo
    end

    def real_boards
      without_demo(Board.non_templates)
    end

    def real_communicators
      without_demo(ChildAccount.where.not(status: "archived"))
    end

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    # group_by_day buckets in Time.zone (not UTC) and zero-fills missing days,
    # so the chart aligns with the Time.zone-based "today" cards.
    def signups_daily_7d
      real_users
        .group_by_day(:created_at, last: 7)
        .count
        .transform_keys(&:to_s)
    end
  end
end
