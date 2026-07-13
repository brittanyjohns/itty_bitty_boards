module Admin
  class UsersController < Admin::ApplicationController
    EDITABLE_ROLES = %w[user admin partner vendor].freeze
    # basic_trial is excluded — trials are owned by the soft-trial flow
    # (DowngradeSoftTrialJob), not manual admin assignment.
    CHANGEABLE_PLAN_TYPES = %w[free basic basic_yearly pro pro_yearly plus premium partner_pro].freeze

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

    def adjust_credits
      @user = User.find(params[:id])

      amount = params[:amount].to_i
      source = params[:source].presence_in(%w[plan topup]) || "plan"
      reason = params[:reason].presence

      if amount.zero?
        render json: { error: "Amount must not be zero" }, status: :unprocessable_content
        return
      end

      txn = CreditService.admin_adjust!(
        @user,
        amount: amount,
        source: source,
        admin: current_user,
        reason: reason,
      )

      render json: {
        success: true,
        transaction_id: txn.id,
        balance: CreditService.balance(@user.reload),
      }
    rescue ActiveRecord::RecordNotFound
      render json: { error: "User not found" }, status: :not_found
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    def update
      @user = User.find(params[:id])
      attrs = user_params
      bool = ActiveModel::Type::Boolean.new

      @user.name = attrs[:name] if attrs.key?(:name)
      @user.email = attrs[:email] if attrs.key?(:email)
      @user.role = attrs[:role] if EDITABLE_ROLES.include?(attrs[:role])
      @user.play_demo = bool.cast(attrs[:play_demo]) if attrs.key?(:play_demo)

      if attrs.key?(:locked)
        locked = bool.cast(attrs[:locked]) || false
        @user.locked = locked
        @user.settings["locked"] = locked
      end

      # Limits live in settings; the model's *_limit= setters save immediately,
      # so write the keys directly instead of assigning attributes.
      @user.settings["board_limit"] = attrs[:board_limit].to_i if attrs[:board_limit].present?
      @user.settings["paid_communicator_limit"] = attrs[:paid_communicator_limit].to_i if attrs[:paid_communicator_limit].present?
      @user.settings["demo_communicator_limit"] = attrs[:demo_communicator_limit].to_i if attrs[:demo_communicator_limit].present?
      @user.skip_plan_setup = true # parity with API admin; setup_limits only runs on plan_type changes anyway

      if @user.save
        redirect_to admin_dashboard_user_path(@user), notice: "User updated.", status: :see_other
      else
        redirect_to admin_dashboard_user_path(@user), alert: @user.errors.full_messages.to_sentence, status: :see_other
      end
    end

    def change_plan
      @user = User.find(params[:id])
      new_plan = params[:plan_type].to_s

      unless CHANGEABLE_PLAN_TYPES.include?(new_plan)
        redirect_to admin_dashboard_user_path(@user), alert: "Unknown plan type: #{new_plan}", status: :see_other
        return
      end

      if new_plan == @user.plan_type
        redirect_to admin_dashboard_user_path(@user), notice: "No change — already on #{new_plan}.", status: :see_other
        return
      end

      case new_plan
      when "free"
        Billing::PlanTransitions.apply_free_plan(@user, "canceled")
      when "partner_pro"
        @user.plan_type = "partner_pro"
        @user.plan_status = "active"
        @user.save!
        User.handle_new_partner_pro_subscription(@user, "partner_pro")
      else
        @user.plan_type = new_plan
        # Without an active status, a previously-canceled user would be
        # plan_stranded? and reconcile_stranded_plan! would revert them to free.
        @user.plan_status = "active"
        @user.save!
      end

      redirect_to admin_dashboard_user_path(@user),
                  notice: "Plan changed to #{new_plan}. Local-only: Stripe was not modified.",
                  status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_dashboard_user_path(@user), alert: e.record.errors.full_messages.to_sentence, status: :see_other
    end

    def send_welcome_email
      @user = User.find(params[:id])
      @user.send_welcome_email(@user.plan_type || "free")
      redirect_to admin_dashboard_user_path(@user), notice: "Welcome email queued for #{@user.email}.", status: :see_other
    end

    def send_setup_email
      @user = User.find(params[:id])
      @user.send_setup_email
      redirect_to admin_dashboard_user_path(@user), notice: "Setup email queued for #{@user.email}.", status: :see_other
    end

    def send_temp_login_email
      @user = User.find(params[:id])
      @user.send_temp_login_email
      redirect_to admin_dashboard_user_path(@user), notice: "Temporary login email queued for #{@user.email}.", status: :see_other
    end

    # Demo-account cleanup only. Uses the same tombstone path as the Mission
    # Control batch cleanup: destroys all content (boards, communicators,
    # docs, ...), anonymizes PII, keeps one hidden row + credit ledger.
    def destroy
      @user = User.find(params[:id])

      unless @user.demo_user? && !@user.admin?
        redirect_to admin_dashboard_user_path(@user),
                    alert: "Only demo accounts can be deleted from here.", status: :see_other
        return
      end

      email = @user.email
      @user.soft_delete_account!(reason: "demo_cleanup", actor_id: current_user.id) unless @user.soft_deleted?
      redirect_to admin_dashboard_users_path,
                  notice: "Demo account #{email} deleted (content destroyed, row anonymized).", status: :see_other
    rescue => e
      Rails.logger.error("[DemoCleanup] Failed to delete user #{params[:id]}: #{e.class} - #{e.message}")
      redirect_to admin_dashboard_user_path(params[:id]), alert: "Delete failed — check logs.", status: :see_other
    end

    private

    def user_params
      params.require(:user).permit(:name, :email, :role, :locked, :play_demo,
                                   :board_limit, :paid_communicator_limit, :demo_communicator_limit)
    end

    def apply_filter(scope)
      case @filter
      when "admin"   then scope.where(role: "admin")
      when "pro"     then scope.where(plan_type: "pro")
      when "partner" then scope.where(plan_type: "partner_pro")
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
