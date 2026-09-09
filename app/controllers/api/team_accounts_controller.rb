class API::TeamAccountsController < API::ApplicationController
  before_action :set_team_account, only: %i[ update destroy ]
  before_action :authorize_manage_team_account!, only: %i[ update destroy ]

  # NOTE: `index` and `show` used to live here and could never have worked —
  # `index` called `TeamAccount#index_api_view`, which does not exist, and
  # `show` called `#show_api_view`, which takes no arguments and does `.map`
  # on a single ChildAccount. Both raised on every call. A team's
  # communicators are already served, correctly, by `Team#show_api_view`'s
  # `accounts` array, which is what the frontend reads.

  def create
    @team = Team.find(params[:team_id])
    @child_account = ChildAccount.find(params[:account_id])

    unless authorized_to_attach?(@team, @child_account)
      return render json: {
        error: "not_authorized",
        message: "You can only add communicators you own to teams you manage.",
      }, status: :forbidden
    end

    @team_account = TeamAccount.new(team: @team, account: @child_account)

    respond_to do |format|
      if @team_account.save
        @team.reload
        format.json { render json: @team.show_api_view(current_user), status: :created }
      else
        format.json { render json: @team_account.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /team_accounts/1 or /team_accounts/1.json
  #
  # Only mutable settings (`active`, `settings`) are updatable — reassigning
  # `team_id`/`child_account_id` is blocked by strong params (Phase 0).
  def update
    if @team_account.update(team_account_params)
      render json: @team_account.team.show_api_view(current_user), status: :ok
    else
      render json: @team_account.errors, status: :unprocessable_content
    end
  end

  # DELETE /team_accounts/1 or /team_accounts/1.json
  def destroy
    @team_account.destroy!

    respond_to do |format|
      format.json { render json: { status: "ok" } }
    end
  end

  private

  # To attach a communicator to a team the caller must OWN the communicator
  # (owner_id) or be a sysadmin, AND manage the target team (its creator or
  # an admin-role member). Phase 0 — previously any user could attach any
  # communicator to any team.
  def authorized_to_attach?(team, child_account)
    return true if current_user.admin?
    return false unless child_account.owner_id == current_user.id

    team.created_by_id == current_user.id ||
      team.team_users.where(user_id: current_user.id, role: "admin").exists?
  end

  # Detaching a communicator from a team, or deactivating it, is a management
  # act — and `TeamAccount#before_destroy` destroys the WHOLE TEAM when the
  # last one goes, cascading team_users and firing every member's
  # BoardSnapshotService. `set_team_account` scopes by the Pundit policy only,
  # which admits every member of the team at any role, so a `restricted`
  # read-only member could delete the team. Same rule as attaching.
  def authorize_manage_team_account!
    return if authorized_to_attach?(@team_account.team, @team_account.account)

    render json: {
      error: "not_authorized",
      message: "You can only change communicators you own on teams you manage.",
    }, status: :forbidden
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_team_account
    @team_account = policy_scope(TeamAccount).find(params[:id])
  end

  # Only allow a list of trusted parameters through. `team_id` and
  # `child_account_id` are intentionally NOT permitted — reassigning a
  # team_account to a different team or communicator is an ownership change
  # that must go through create/destroy, not a mass-assignment update.
  def team_account_params
    params.require(:team_account).permit(:active, :settings)
  end
end
