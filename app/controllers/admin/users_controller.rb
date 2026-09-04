module Admin
  class UsersController < Admin::ApplicationController
    EDITABLE_ROLES = %w[user admin partner vendor].freeze
    # basic_trial is excluded — trials are owned by the soft-trial flow
    # (DowngradeSoftTrialJob), not manual admin assignment.
    CHANGEABLE_PLAN_TYPES = %w[free basic basic_yearly pro pro_yearly plus premium partner_pro].freeze
    # Matches the React admin's AdminUserSettingsForm option list exactly —
    # not the app's actual Polly voice catalog — since these are what's
    # already stored in settings["voice"]["name"] for existing users.
    VOICE_NAMES = %w[alloy onyx shimmer nova fable ash coral sage].freeze
    VOICE_LANGUAGES = {
      "en-US" => "English", "es-US" => "Spanish", "fr-FR" => "French", "de-DE" => "German",
      "it-IT" => "Italian", "ja-JP" => "Japanese", "ko-KR" => "Korean", "nl-NL" => "Dutch",
      "pl-PL" => "Polish", "pt-PT" => "Portuguese", "ru-RU" => "Russian", "zh-CN" => "Chinese",
    }.freeze

    def index
      @sort = params[:sort].presence_in(%w[created_at email name plan_type plan_status sign_in_count current_sign_in_at boards signup_platform]) || "created_at"
      @dir = params[:dir].presence_in(%w[asc desc]) || "desc"
      @filter = params[:filter]
      @search = params[:search]
      @hide_demo = ActiveModel::Type::Boolean.new.cast(params[:hide_demo]) || false

      scope = User.all
      scope = apply_filter(scope)
      # The toggle and the "Demo accounts" filter ask opposite questions. The
      # explicit filter wins rather than the pair silently rendering an empty
      # table that looks like a bug.
      scope = scope.non_demo if @hide_demo && @filter != "demo"
      scope = scope.where("email ILIKE ? OR name ILIKE ?", "%#{@search}%", "%#{@search}%") if @search.present?

      @users =
        case @sort
        when "boards"
          sorted = scope.includes(:boards).sort_by { |u| u.boards.size }
          @dir == "desc" ? sorted.reverse : sorted
        when "signup_platform"
          # jsonb key, not a column — and accounts created before signup
          # context shipped have no key at all, so they sort last either way
          # rather than clumping at the top of an ascending sort.
          #
          # Built in Arel rather than an interpolated Arel.sql string, same
          # reasoning as User.demo_accounts: @dir is validated against a
          # two-element allowlist above, but an interpolated ORDER BY is
          # indistinguishable from injection to Brakeman (and to the next
          # person who widens that allowlist).
          scope.order(signup_platform_ordering)
        else
          scope.order(@sort => @dir.to_sym)
        end

      @total_count = scope.count
    end

    def show
      @user = User.find(params[:id])
      @boards = @user.boards.order(updated_at: :desc).limit(50)
      @communicators = @user.communicator_accounts.order(:created_at)
      @recent_events = AnalyticsEvent.where(user_id: @user.id).recent.limit(20)
      @credit_balance = CreditService.balance(@user)
      # Gated on HAVING a subscription rather than on being a partner: the same
      # snapshot powers the Partner Pilot card and the pre-swap warning shown to
      # a user who isn't a partner yet. Never raises; see the service.
      @stripe_sub = Billing::PartnerProStatus.snapshot(@user) if @user.stripe_subscription_id.present?
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
      # An OVERRIDE of the plan-resolved board_limit — blank clears it back to
      # the plan default rather than leaving the last override in place.
      if attrs.key?(:board_limit)
        if attrs[:board_limit].to_s.strip.empty?
          @user.settings.delete("board_limit")
        else
          @user.settings["board_limit"] = attrs[:board_limit].to_i
        end
      end
      @user.settings["paid_communicator_limit"] = attrs[:paid_communicator_limit].to_i if attrs[:paid_communicator_limit].present?
      @user.settings["demo_communicator_limit"] = attrs[:demo_communicator_limit].to_i if attrs[:demo_communicator_limit].present?

      # Presence-guarded, never truthiness — an absent key means "leave it
      # alone". The list is the models' own (DisplaySettingsDefaults), so a
      # flag the server defaults is always one an admin can also set.
      DisplaySettingsDefaults::REQUIRED_SETTINGS.each do |key|
        next unless attrs.key?(key)

        @user.settings[key] = bool.cast(attrs[key]) || false
      end

      if attrs[:voice].present?
        voice = (@user.settings["voice"] || {}).merge(attrs[:voice].to_h.compact_blank)
        @user.settings["voice"] = voice
      end

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

      # partner_pro is deliberately exempt from the no-change guard: the local
      # flip happens before the Stripe call, so a failed swap would otherwise be
      # unrecoverable from this page — the admin could never retry.
      if new_plan == @user.plan_type && new_plan != "partner_pro"
        redirect_to admin_dashboard_user_path(@user), notice: "No change — already on #{new_plan}.", status: :see_other
        return
      end

      stripe_result = nil

      case new_plan
      when "free"
        Billing::PlanTransitions.apply_free_plan(@user, "canceled")
      when "partner_pro"
        @user.plan_type = "partner_pro"
        @user.plan_status = "active"
        @user.save!
        # swap_existing: an admin upgrade is the case where the user already has
        # a subscription sitting on a basic/pro price, whose metadata the next
        # webhook would write back over partner_pro.
        stripe_result = User.handle_new_partner_pro_subscription(@user, "partner_pro", swap_existing: true)
      else
        @user.plan_type = new_plan
        # Without an active status, a previously-canceled user would be
        # plan_stranded? and reconcile_stranded_plan! would revert them to free.
        @user.plan_status = "active"
        @user.save!
      end

      if stripe_result.is_a?(Hash) && !stripe_result[:ok]
        redirect_to admin_dashboard_user_path(@user), alert: plan_change_message(new_plan, stripe_result), status: :see_other
      else
        redirect_to admin_dashboard_user_path(@user), notice: plan_change_message(new_plan, stripe_result), status: :see_other
      end
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

    def send_partner_welcome_email
      @user = User.find(params[:id])
      @user.send_partner_welcome_email
      redirect_to admin_dashboard_user_path(@user), notice: "Partner welcome email queued for #{@user.email}.", status: :see_other
    end

    def export
      send_data User.all.to_csv,
                filename: "users-#{Time.zone.now.strftime("%Y-%m-%d")}.csv",
                type: "text/csv"
    end

    # Demo-account bulk cleanup only — same restriction as single-user
    # #destroy below. The JSON API's destroy_users has no such restriction,
    # but this HTML action deliberately keeps parity with the existing
    # single-delete guardrail rather than the broader JSON behavior.
    def destroy_users
      user_ids = Array(params[:user_ids])
      if user_ids.blank?
        redirect_to admin_dashboard_users_path, alert: "No users selected.", status: :see_other
        return
      end

      # `demo_accounts` already excludes admins via `non_admin`, which spells the
      # check as "role IS NULL OR role != 'admin'". A plain `where.not(role:)`
      # compiles to `role != 'admin'`, which is NULL — and therefore false — for
      # the NULL role every ordinary signup has, so stacking it here skipped
      # every real demo account and reported it as "not a demo account".
      users = User.where(id: user_ids).demo_accounts
      skipped = user_ids.size - users.size
      users.each { |u| u.soft_delete_account!(reason: "admin_deleted", actor_id: current_user.id) unless u.soft_deleted? }

      message = "Deleted #{users.size} demo account(s)."
      message += " Skipped #{skipped} selected user(s) that weren't demo accounts." if skipped.positive?
      redirect_to admin_dashboard_users_path, notice: message, status: :see_other
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
    rescue Board::MarketplaceProtectedError => e
      # Ahead of the blanket rescue below, which would otherwise flatten this
      # into "check logs". Shouldn't be reachable — only demo accounts get here
      # and a demo board is never sold — but a silent mystery is the wrong
      # failure mode for a guard whose whole job is to be explicable.
      redirect_to admin_dashboard_user_path(params[:id]),
                  alert: "\"#{e.board.name}\" is sold as a printable — release protection on the printable first.",
                  status: :see_other
    rescue => e
      Rails.logger.error("[DemoCleanup] Failed to delete user #{params[:id]}: #{e.class} - #{e.message}")
      redirect_to admin_dashboard_user_path(params[:id]), alert: "Delete failed — check logs.", status: :see_other
    end

    private

    def signup_platform_ordering
      key = Arel::Nodes::InfixOperation.new(
        "->>", User.arel_table[:settings], Arel::Nodes.build_quoted("signup_platform")
      )
      (@dir == "asc" ? key.asc : key.desc).nulls_last
    end

    def user_params
      params.require(:user).permit(:name, :email, :role, :locked, :play_demo,
                                   :board_limit, :paid_communicator_limit, :demo_communicator_limit,
                                   *DisplaySettingsDefaults::REQUIRED_SETTINGS,
                                   voice: [:name, :language])
    end

    # What actually happened, plan branch by plan branch. The partner branch is
    # the only one that touches Stripe, and an admin has to be able to tell a
    # landed swap from a silent no-op — the whole point of the change.
    #
    # The raw Stripe error is shown on purpose: this is a server-rendered admin
    # page behind require_admin!, not an API response, so the never-leak-
    # internals rule doesn't bind and the detail is what makes it actionable.
    def plan_change_message(new_plan, stripe_result)
      base = "Plan changed to #{new_plan}."
      return "#{base} Subscription canceled locally, limits reset, free credits granted." if new_plan == "free"
      return "#{base} Local-only: Stripe was not modified." unless stripe_result.is_a?(Hash)

      sub = stripe_result[:subscription_id]
      trial = stripe_result[:trial_end]
      trial_note = trial.present? ? " Trial ends #{trial.to_date.strftime("%b %-d, %Y")}." : ""

      case stripe_result[:action]
      when :swapped
        was = [stripe_result[:previous_price_id], stripe_result[:previous_interval],
               stripe_result[:previous_amount], stripe_result[:previous_status]].compact.join(", ")
        "#{base} Stripe subscription #{sub} moved onto the Partner Pro price " \
          "(was #{was} — no proration credit issued).#{trial_note}"
      when :created
        "#{base} Created Stripe trial subscription #{sub}.#{trial_note}"
      when :already_on_price
        "#{base} Stripe subscription #{sub} was already on the Partner Pro price."
      when :reused
        "#{base} Stripe subscription #{sub} left as-is."
      when :skipped
        "#{base} Changed locally, but STRIPE_PRICE_PARTNER_PRO is not configured — Stripe was NOT modified."
      else
        "#{base} Changed locally, but Stripe failed: #{stripe_result[:error]}. " \
          "The subscription still points at the old price and a webhook may revert the plan."
      end
    end

    def apply_filter(scope)
      case @filter
      when "admin"   then scope.where(role: "admin")
      when "pro"     then scope.where(plan_type: "pro")
      when "partner" then scope.where(plan_type: "partner_pro")
      when "basic"  then scope.where(plan_type: "basic")
      when "free"   then scope.where(plan_type: "free")
      when "trial"  then scope.trialing
      when "demo"   then scope.demo_accounts
      when "ios", "android", "web" then scope.where("users.settings ->> 'signup_platform' = ?", @filter)
      when "locked" then scope.where(locked: true)
      else scope
      end
    end
  end
end
