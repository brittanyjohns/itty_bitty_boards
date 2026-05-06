module MissionControl
  class UsageMetrics
    def self.call = new.call

    def call
      {
        ai_boards_today:        Board.ai_generated.where(created_at: today).count,
        ai_boards_7d:           Board.ai_generated.where(created_at: 7.days.ago..).count,
        ai_boards_30d:          Board.ai_generated.where(created_at: 30.days.ago..).count,
        ai_prompts_today:       OpenaiPrompt.where(created_at: today).count,
        ai_prompts_30d:         OpenaiPrompt.where(created_at: 30.days.ago..).count,
        ai_failures_today:      AnalyticsEvent.for_event("ai_generation_failed").today.count,
        ai_failures_7d:         AnalyticsEvent.for_event("ai_generation_failed").since(7.days.ago).count,
        boards_by_type:         boards_by_type,
        word_events_by_day:     WordEvent.group_by_day(:created_at, last: 7).count,
      }
    end

    private

    def today
      Time.zone.now.beginning_of_day..Time.zone.now.end_of_day
    end

    def boards_by_type
      Board.non_templates
           .group(:board_type)
           .count
           .sort_by { |_, v| -v }
           .to_h
    end
  end
end
