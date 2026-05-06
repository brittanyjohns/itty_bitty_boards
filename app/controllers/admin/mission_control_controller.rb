module Admin
  class MissionControlController < Admin::ApplicationController
    def show
      @overview = MissionControl::OverviewMetrics.call
      @revenue  = MissionControl::RevenueMetrics.call
      @usage    = MissionControl::UsageMetrics.call
      @health   = MissionControl::SystemHealthMetrics.call
      @recent_events = AnalyticsEvent.recent.limit(25).includes(:user)
    end
  end
end
