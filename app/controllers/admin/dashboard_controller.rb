module Admin
  class DashboardController < Admin::ApplicationController
    include MissionControl::ExcludesDemo

    def index
      real_users = User.non_admin.non_demo
      @user_count = real_users.count
      @board_count = without_demo(Board.non_templates).count
      @today_signups = real_users.where("created_at >= ?", Time.zone.today.beginning_of_day).count
      @demo_user_count = User.demo_accounts.count
    end
  end
end
