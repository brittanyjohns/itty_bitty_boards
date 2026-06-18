module Admin
  class MissionControlController < Admin::ApplicationController
    def show
      @overview = MissionControl::OverviewMetrics.call
      @revenue  = MissionControl::RevenueMetrics.call
      @usage    = MissionControl::UsageMetrics.call
      @health   = MissionControl::SystemHealthMetrics.call
      @recent_events = AnalyticsEvent.recent.limit(25).includes(:user)

      demo_users = User.demo_accounts.includes(:boards)
      @demo_user_count = demo_users.count
      @demo_users_preview = demo_users.sort_by { |u| -u.boards.size }.first(10).map do |u|
        { id: u.id, email: u.email, boards: u.boards.size, created_at: u.created_at }
      end
    end

    def cleanup_demo
      keep_count = (params[:keep_count] || 5).to_i
      exclude_ids = params[:exclude_ids].to_s.split(",").map(&:strip).select(&:present?).map(&:to_i)

      demo_users = User.demo_accounts.includes(:boards)
      excluded = demo_users.where(id: exclude_ids)
      candidates = demo_users.where.not(id: exclude_ids).where.not(role: "admin")

      ranked = candidates.sort_by { |u| -u.boards.size }
      kept = ranked.first(keep_count)
      to_delete = ranked.drop(keep_count)

      deleted_count = 0
      errors = []
      to_delete.each do |user|
        destroy_demo_user!(user)
        deleted_count += 1
      rescue => e
        Rails.logger.error("[DemoCleanup] Failed to delete #{user.email}: #{e.class} - #{e.message}")
        errors << user.email
      end

      flash_msg = "Deleted #{deleted_count} demo user#{"s" unless deleted_count == 1}."
      flash_msg += " Kept #{kept.size + excluded.size}." if kept.any? || excluded.any?
      flash_msg += " #{errors.size} error#{"s" unless errors.size == 1} (check logs)." if errors.any?

      redirect_to admin_mission_control_path, notice: flash_msg
    end

    private

    def destroy_demo_user!(user)
      user.soft_delete_account!(reason: "demo_cleanup", actor_id: current_user.id) unless user.soft_deleted?
    end
  end
end
