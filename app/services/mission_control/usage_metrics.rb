module MissionControl
  class UsageMetrics
    include ExcludesDemo

    def self.call = new.call

    def call
      {
        # Board Builder
        builder_sets_today:     builder_roots.where(created_at: today).count,
        builder_sets_7d:        builder_roots.where(created_at: 7.days.ago..).count,
        builder_sets_30d:       builder_roots.where(created_at: 30.days.ago..).count,

        # Credit usage
        credits_spent_today:    credit_spends.where(created_at: today).sum(:amount).abs,
        credits_spent_7d:       credit_spends.where(created_at: 7.days.ago..).sum(:amount).abs,
        credits_spent_30d:      credit_spends.where(created_at: 30.days.ago..).sum(:amount).abs,

        # Communicators
        communicators_created_today: communicators.where(created_at: today).count,
        communicators_created_7d:    communicators.where(created_at: 7.days.ago..).count,

        # Communicator sessions (sign-ins)
        communicator_sessions_7d:  communicators.where(last_sign_in_at: 7.days.ago..).count,
        communicator_sessions_30d: communicators.where(last_sign_in_at: 30.days.ago..).count,

        # AI prompts & failures (kept from original)
        ai_prompts_today:       ai_prompts.where(created_at: today).count,
        ai_prompts_30d:         ai_prompts.where(created_at: 30.days.ago..).count,
        ai_failures_today:      without_demo(AnalyticsEvent.for_event("ai_generation_failed").today).count,
        ai_failures_7d:         without_demo(AnalyticsEvent.for_event("ai_generation_failed").since(7.days.ago)).count,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    def builder_roots
      without_demo(Board.where("(settings->>'builder_root')::boolean = true"))
    end

    def credit_spends
      without_demo(CreditTransaction.spends)
    end

    def communicators
      without_demo(ChildAccount.all)
    end

    def ai_prompts
      without_demo(OpenaiPrompt.all)
    end
  end
end
