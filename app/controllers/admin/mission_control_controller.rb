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
      candidates = demo_users.where.not(id: exclude_ids)

      ranked = candidates.sort_by { |u| -u.boards.size }
      kept = ranked.first(keep_count)
      to_delete = ranked.drop(keep_count)

      deleted_count = 0
      errors = []
      to_delete.each do |user|
        destroy_demo_user!(user)
        deleted_count += 1
      rescue => e
        errors << "#{user.email}: #{e.message}"
      end

      flash_msg = "Deleted #{deleted_count} demo user#{"s" unless deleted_count == 1}."
      flash_msg += " Kept #{kept.size + excluded.size} (top #{keep_count} by boards + #{excluded.size} excluded)." if kept.any? || excluded.any?
      flash_msg += " Errors: #{errors.join("; ")}" if errors.any?

      redirect_to admin_mission_control_path, notice: flash_msg
    end

    private

    def destroy_demo_user!(user)
      User.transaction do
        user.boards.destroy_all
        user.communicator_accounts.destroy_all
        user.board_groups.destroy_all
        user.word_events.delete_all
        user.credit_transactions.delete_all
        user.openai_prompts.delete_all
        user.team_users.delete_all
        user.subscriptions.delete_all
        user.profile&.destroy
        user.delete
      end
    end
  end
end
