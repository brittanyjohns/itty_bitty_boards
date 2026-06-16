module API
  class StatsController < ApplicationController
    skip_before_action :authenticate_token!
    before_action :authenticate_stats_token!

    def index
      render json: Stats::Snapshot.call
    end

    private

    def authenticate_stats_token!
      expected = ENV["STATS_TOKEN"].to_s
      given = request.headers.fetch("Authorization", "").split(" ").last.to_s

      if expected.blank? || !ActiveSupport::SecurityUtils.secure_compare(given, expected)
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end
  end
end
