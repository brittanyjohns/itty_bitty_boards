module MissionControl
  class UsageMetrics
    def self.call = new.call

    def call
      {
        # Board Builder
        builder_sets_today:     builder_roots.where(created_at: today).count,
        builder_sets_7d:        builder_roots.where(created_at: 7.days.ago..).count,
        builder_sets_30d:       builder_roots.where(created_at: 30.days.ago..).count,

        # Credit usage
        credits_spent_today:    CreditTransaction.spends.where(created_at: today).sum(:amount).abs,
        credits_spent_7d:       CreditTransaction.spends.where(created_at: 7.days.ago..).sum(:amount).abs,
        credits_spent_30d:      CreditTransaction.spends.where(created_at: 30.days.ago..).sum(:amount).abs,

        # Communicators
        communicators_created_today: ChildAccount.where(created_at: today).count,
        communicators_created_7d:    ChildAccount.where(created_at: 7.days.ago..).count,

        # Communicator sessions (sign-ins)
        communicator_sessions_7d:  ChildAccount.where(last_sign_in_at: 7.days.ago..).count,
        communicator_sessions_30d: ChildAccount.where(last_sign_in_at: 30.days.ago..).count,

        # AI prompts & failures (kept from original)
        ai_prompts_today:       OpenaiPrompt.where(created_at: today).count,
        ai_prompts_30d:         OpenaiPrompt.where(created_at: 30.days.ago..).count,
        ai_failures_today:      AnalyticsEvent.for_event("ai_generation_failed").today.count,
        ai_failures_7d:         AnalyticsEvent.for_event("ai_generation_failed").since(7.days.ago).count,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    def builder_roots
      Board.where("(settings->>'builder_root')::boolean = true")
    end
  end
end
