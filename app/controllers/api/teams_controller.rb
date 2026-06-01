class API::TeamsController < API::ApplicationController
  before_action :set_team, only: %i[ show edit update destroy remove_board invite ]
  before_action :authorize_team_member!, only: %i[ create_board ]
  # after_action :verify_policy_scoped, only: :index

  # GET /teams or /teams.json
  def index
    # @teams = policy_scope(Team)
    # @teams = current_user.teams.where(created_by: current_user).includes(:team_users)
    @teams = current_user.teams.includes(:team_users)
    render json: @teams.map { |team| team.index_api_view(current_user) }
  end

  # GET /teams/1 or /teams/1.json
  def show
    render json: @team.show_api_view(current_user)
  end

  def remaining_boards
    @team = Team.find(params[:id])
    board_ids = @team.boards.pluck(:id)
    @boards = current_user.boards.where.not(id: board_ids).alphabetical

    render json: @boards
  end

  def unassigned_accounts
    @team = Team.find(params[:id])
    user_accounts = current_user.communicator_accounts
    unassigned_accounts = user_accounts.where.not(id: @team.accounts.pluck(:id)).alphabetical
    render json: unassigned_accounts.map(&:api_view)
  end

  # GET /teams/new
  def new
    @team = Team.new
  end

  # GET /teams/1/edit
  def edit
  end

  def invite
    user_email = team_user_params[:email]
    user_role = invite_role
    @team = Team.find(params[:id])

    # Block role-change of an existing owner-pinned member, and block
    # self-promotion to admin by non-owners. See issue #166.
    existing_user = User.find_by(email: user_email)
    if existing_user
      existing_membership = TeamUser.find_by(user_id: existing_user.id, team_id: @team.id)
      if existing_membership && existing_membership.role != user_role
        if @team.account_owner?(existing_user) && existing_user != current_user
          return render_team_permission_error("cannot_change_owner_role",
                                              "You cannot change the role of the communicator's owner.")
        end
        if existing_user == current_user && user_role == "admin" &&
           !current_user.admin? && !@team.account_owner?(current_user)
          return render_team_permission_error("cannot_self_promote",
                                              "You cannot promote yourself to admin.")
        end
      end
    end

    @user = User.invite_new_user_to_team!(user_email, current_user, @team, user_role)
    unless @user
      return render json: { error: "User not invited. Something went wrong." }, status: :unprocessable_entity
    end
    @team.upsert_member!(@user, user_role)

    render json: @team.show_api_view(current_user), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors }, status: :unprocessable_entity
  end

  def remove_member
    @team = Team.find(params[:id])
    @user = User.find_by(email: params[:email])
    return render json: { error: "User not found" }, status: :not_found unless @user

    @team_user = TeamUser.find_by(user_id: @user.id, team_id: @team.id)
    return render json: { error: "Not a team member" }, status: :not_found unless @team_user

    # Owner of any child_account on this team is owner-pinned: only the
    # owner themselves (or a system admin) can remove them. Issue #166 —
    # prevents an SLP supervisor from removing the parent owner after the
    # claim hand-off.
    if @team.account_owner?(@user) && @user != current_user && !current_user.admin?
      return render_team_permission_error("cannot_remove_owner",
                                          "You cannot remove the communicator's owner from the team.")
    end

    @team_user.destroy!
    render json: @team.show_api_view(current_user)
  end

  # POST /teams or /teams.json
  def create
    @team = Team.new
    # @team.name = team_params[:name]&.upcase
    @team.name = team_params[:name]
    account_id = params.dig(:team, :account_id)
    @team.created_by = current_user
    Rails.logger.info("Creating team with name: #{@team.name}, created_by: #{current_user.id}, account_id: #{account_id}")

    respond_to do |format|
      if @team.save
        @team.upsert_member!(current_user, "admin")
        initial_account = current_user.communicator_accounts.find_by(id: account_id) if account_id.present?
        @team.add_communicator!(initial_account) if initial_account

        format.json { render json: @team.show_api_view(current_user), status: :created }
      else
        format.json { render json: @team.errors, status: :unprocessable_entity }
      end
    end
  end

  def accept_invite
    @team = Team.find(params[:id])
    @user = User.find_by(email: params[:email])
    @team_user = TeamUser.find_by(user_id: @user.id, team_id: @team.id)
  end

  def accept_invite_patch
    @team = Team.find(params[:id])
    @user = User.find_by(email: team_user_params[:email])
    @team_user = TeamUser.find_by(user_id: @user.id, team_id: @team.id)
    @team_user.accept_invitation!
  end

  def create_board
    @board = Board.find(params[:board_id])
    @team_board = @team.add_board!(@board, current_user.id)
    if @team_board.save
      render json: @team.show_api_view(current_user)
    else
      render json: @team_board.errors, status: :unprocessable_entity
    end
  end

  def remove_board
    # @team = Team.find(params[:id])
    @board = Board.find(params[:board_id])
    @team.remove_board!(@board)
    render json: @team.show_api_view(current_user)
  end

  # PATCH/PUT /teams/1 or /teams/1.json
  def update
    respond_to do |format|
      if @team.update(team_params)
        format.html { redirect_to team_url(@team), notice: "Team was successfully updated." }
        format.json { render :show, status: :ok, location: @team }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @team.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /teams/1 or /teams/1.json
  def destroy
    @team.destroy!

    respond_to do |format|
      format.json { render json: { status: "ok" } }
    end
  end

  private

  def render_team_permission_error(error_key, message)
    render json: { error: error_key, message: message }, status: :forbidden
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_team
    # @team = policy_scope(Team).find(params[:id])
    @team = Team.with_artifacts.find(params[:id])
  end

  # Any team member (admin, supervisor, member) — or a system admin —
  # may add boards to the team's library. Non-members get 403. Issue
  # #216 — closes the gap where any signed-in user could write to any
  # team's `team_boards`.
  def authorize_team_member!
    @team = Team.with_artifacts.find(params[:id])
    return if current_user.admin?
    return if @team.team_users.where(user_id: current_user.id, role: TeamUser::ROLES).exists?
    render_team_permission_error("not_a_team_member",
                                 "You must be on this team to add boards to it.")
  end

  def team_user_params
    params.require(:team_user).permit(:email)
  end

  def invite_role
    role = params.dig(:team_user, :role).to_s
    TeamUser::ROLES.include?(role) ? role : "member"
  end

  # Only allow a list of trusted parameters through.
  def team_params
    params.require(:team).permit(:name)
  end
end
