module API
  module Admin
    class MissionControlController < API::Admin::ApplicationController
      def show
        render json: {
          overview:      MissionControl::OverviewMetrics.call,
          revenue:       MissionControl::RevenueMetrics.call,
          usage:         MissionControl::UsageMetrics.call,
          health:        MissionControl::SystemHealthMetrics.call,
          recent_events: recent_events_json,
        }
      end

      private

      def recent_events_json
        AnalyticsEvent.recent.limit(25).includes(:user).map do |event|
          {
            id:         event.id,
            event_type: event.event_type,
            user_email: event.user&.email,
            occurred_at: event.occurred_at,
            metadata:   event.metadata,
          }
        end
      end
    end
  end
end
