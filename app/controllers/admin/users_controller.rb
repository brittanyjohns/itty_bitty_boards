module Admin
  class UsersController < Admin::ApplicationController
    def index
      @sort = params[:sort].presence_in(%w[created_at email name plan_type sign_in_count boards]) || "created_at"
      @dir = params[:dir].presence_in(%w[asc desc]) || "desc"
      @filter = params[:filter]
      @search = params[:search]

      scope = User.all
      scope = apply_filter(scope)
      scope = scope.where("email ILIKE ? OR name ILIKE ?", "%#{@search}%", "%#{@search}%") if @search.present?

      if @sort == "boards"
        @users = scope.includes(:boards).sort_by { |u| u.boards.size }
        @users.reverse! if @dir == "desc"
      else
        @users = scope.order(@sort => @dir.to_sym)
      end

      @total_count = scope.count
    end

    def show
      @user = User.find(params[:id])
      @boards = @user.boards.order(updated_at: :desc).limit(50)
      @communicators = @user.communicator_accounts.order(:created_at)
      @recent_events = AnalyticsEvent.where(user_id: @user.id).recent.limit(20)
      @credit_balance = CreditService.balance(@user)
    end

    private

    def apply_filter(scope)
      case @filter
      when "admin"  then scope.where(role: "admin")
      when "pro"    then scope.where(plan_type: "pro")
      when "basic"  then scope.where(plan_type: "basic")
      when "free"   then scope.where(plan_type: "free")
      when "trial"  then scope.where(plan_type: "basic_trial")
      when "demo"   then scope.demo_accounts
      when "locked" then scope.where(locked: true)
      else scope
      end
    end
  end
end
