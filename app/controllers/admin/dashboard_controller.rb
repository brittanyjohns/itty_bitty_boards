module Admin
  class DashboardController < Admin::ApplicationController
    def index
      @user_count   = User.count
      @board_count  = Board.count
      @today_signups = User.where("created_at >= ?", Time.zone.today.beginning_of_day).count
    end
  end
end
