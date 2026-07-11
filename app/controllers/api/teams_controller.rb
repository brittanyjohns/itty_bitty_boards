class API::TeamsController < API::ApplicationController
  # `accept_invite` is the pre-sign-in invite preview landing page — it must
  # work without a token, validated instead by the invite uuid in the URL.
  skip_before_action :authenticate_token!, only: %i[ accept_invite ]
  before_action :set_team, only: %i[ show edit update destroy remove_board invite ]
  before_action :authorize_team_read!, only: %i[ show ]
  before_action :authorize_team_manage!, only: %i[ update destroy invite remove_member ]
  before_action :authorize_remove_board!, only: %i[ remove_board ]
  before_action :authorize_team_library_writer!, only: %i[ create_board ]
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
    # Raw requested role — the owner-pin / self-promote guards below inspect
    # the requested value (including "admin") so they can return their
    # specific errors before the invite-role validation rejects it.
    requested_role = params.dig(:team_user, :role).to_s

    # Block role-change of an existing owner-pinned member, and block
    # self-promotion to admin by non-owners. See issue #166. These run
    # before role validation so the specific 403 wins over a generic 422.
    existing_user = User.find_by(email: user_email)
    if existing_user
      existing_membership = TeamUser.find_by(user_id: existing_user.id, team_id: @team.id)
      if existing_membership && existing_membership.role != requested_role
        if @team.account_owner?(existing_user) && existing_user != current_user
          return render_team_permission_error("cannot_change_owner_role",
                                              "You cannot change the role of the communicator's owner.")
        end
        if existing_user == current_user && requested_role == "admin" &&
           !current_user.admin? && !@team.account_owner?(current_user)
          return render_team_permission_error("cannot_self_promote",
                                              "You cannot promote yourself to admin.")
        end
      end
    end

    # Validate the invite role: only supervisor / member / restricted may be
    # granted via invite. "admin" is the owner's role (never invited) and any
    # junk value is rejected — no silent coercion (Phase 2).
    user_role = invite_role(requested_role)
    unless user_role
      return render_team_permission_error(
        "invalid_role",
        "Role must be one of supervisor, member, or restricted.",
        :unprocessable_content,
      )
    end

    @user = User.invite_new_user_to_team!(user_email, current_user, @team, user_role)
    unless @user
      return render json: { error: "User not invited. Something went wrong." }, status: :unprocessable_content
    end
    @team.upsert_member!(@user, user_role)

    render json: @team.show_api_view(current_user), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors }, status: :unprocessable_content
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
    # Hosting a team is a Pro (owner-side) feature — decision 3: the owner's
    # plan hosts the team, members participate per role regardless of plan.
    # Free-trial owners pass, consistent with the rest of the app.
    unless current_user.paid_plan? || current_user.free_trial?
      return render_team_permission_error(
        "pro_required",
        "Creating a team is a Pro feature. Upgrade to build a care team.",
      )
    end

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
        format.json { render json: @team.errors, status: :unprocessable_content }
      end
    end
  end

  # GET /api/teams/:id/accept_invite?token=<uuid>
  #
  # Public invite-preview for the pre-sign-in landing page. Identity is
  # established SOLELY by matching the `token` against the invited user's
  # `uuid` — never by an email param. Returns a masked-email preview so the
  # landing page can say "you were invited to <team> as <role>". 404 (with a
  # structured error) if the team/token/membership don't line up, so we never
  # leak whether a given team or email exists.
  def accept_invite
    team = Team.find_by(id: params[:id])
    invited_user = User.find_by(uuid: params[:token].to_s) if params[:token].present?
    membership = TeamUser.find_by(user_id: invited_user.id, team_id: team.id) if team && invited_user

    unless membership
      return render json: {
        error: "invite_not_found",
        message: "This invitation link is invalid or has expired.",
      }, status: :not_found
    end

    render json: {
      team_name: team.name,
      invited_by_name: team.created_by&.display_name,
      role: membership.role,
      email: masked_email(invited_user.email),
    }, status: :ok
  end

  # PATCH /api/teams/:id/accept_invite_patch?token=<uuid>
  #
  # Authenticated acceptance. Identity is `current_user` (never the email
  # param — a spoofed email is ignored). The URL `token` must match
  # `current_user.uuid`, so following someone else's invite link while signed
  # in as a different account is rejected. Structured errors only, never 500.
  def accept_invite_patch
    team = Team.find_by(id: params[:id])
    return render_invite_not_found unless team

    membership = TeamUser.find_by(user_id: current_user.id, team_id: team.id)
    return render_invite_not_found unless membership

    if params[:token].to_s != current_user.uuid.to_s
      return render json: {
        error: "invite_token_mismatch",
        message: "This invitation was issued to a different account. Sign in as the invited user to accept it.",
      }, status: :forbidden
    end

    membership.accept_invitation!
    render json: team.show_api_view(current_user), status: :ok
  end

  def create_board
    @board = Board.find(params[:board_id])
    @team_board = @team.add_board!(@board, current_user.id)
    if @team_board.save
      render json: @team.show_api_view(current_user)
    else
      render json: @team_board.errors, status: :unprocessable_content
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
        format.json { render json: @team.show_api_view(current_user), status: :ok }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @team.errors, status: :unprocessable_content }
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

  def render_team_permission_error(error_key, message, status = :forbidden)
    render json: { error: error_key, message: message }, status: status
  end

  def render_invite_not_found
    render json: {
      error: "not_a_team_member",
      message: "No pending invitation was found for your account on this team.",
    }, status: :not_found
  end

  # "brittany@example.com" -> "b*******@example.com". Keeps the domain (so the
  # invitee recognizes their own address) while not exposing the full local
  # part on the public preview endpoint.
  def masked_email(email)
    return nil if email.blank?
    local, domain = email.split("@", 2)
    return email if domain.blank?
    masked_local = local.length <= 1 ? "#{local}*" : "#{local[0]}#{'*' * (local.length - 1)}"
    "#{masked_local}@#{domain}"
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_team
    # @team = policy_scope(Team).find(params[:id])
    @team = Team.with_artifacts.find(params[:id])
  end

  # True when the caller can MANAGE the team: rename, delete, invite, or
  # remove members. That's the team owner (creator), any communicator
  # account owner on the team, or a system admin. Phase 0 lockdown.
  def can_manage_team?
    current_user.admin? ||
      @team.created_by_id == current_user.id ||
      @team.account_owner?(current_user)
  end

  # READ access to the team (show): members only — don't leak other teams.
  # Any membership role (including restricted) can view; owners/admins too.
  def authorize_team_read!
    @team ||= Team.with_artifacts.find(params[:id])
    return if can_manage_team?
    return if @team.team_users.where(user_id: current_user.id).exists?
    render_team_permission_error("not_a_team_member",
                                 "You must be on this team to view it.")
  end

  # MANAGE gate for update/destroy/invite/remove_member. Phase 0 closed the
  # hole where any authenticated user could mutate any team.
  def authorize_team_manage!
    @team ||= Team.with_artifacts.find(params[:id])
    return if can_manage_team?
    render_team_permission_error("not_authorized",
                                 "Only the account owner or team owner can manage this team.")
  end

  # remove_board: curate roles (admin/supervisor) or the team owner /
  # account owner / sysadmin.
  def authorize_remove_board!
    @team ||= Team.with_artifacts.find(params[:id])
    return if can_manage_team?
    return if @team.team_users.where(user_id: current_user.id, role: User::CURATE_ROLES).exists?
    render_team_permission_error("not_authorized",
                                 "Only a supervisor or the team owner can remove boards from this team.")
  end

  # Any team member allowed to WRITE the team library (admin, supervisor,
  # member) — or a system admin — may add boards to the team's library.
  # `restricted` (read-only) and non-members get 403. Issue #216 — closes
  # the gap where any signed-in user could write to any team's `team_boards`.
  def authorize_team_library_writer!
    @team = Team.with_artifacts.find(params[:id])
    return if current_user.admin?
    return if @team.team_users.where(user_id: current_user.id, role: TeamUser::LIBRARY_ROLES).exists?
    render_team_permission_error("not_a_team_member",
                                 "You must be on this team to add boards to it.")
  end

  def team_user_params
    params.require(:team_user).permit(:email)
  end

  # Invitable roles only — "admin" is the owner's role (never invited). Any
  # value outside supervisor|member|restricted returns nil so the caller can
  # render a 422 instead of silently coercing to member (Phase 2).
  INVITABLE_ROLES = %w[supervisor member restricted].freeze

  def invite_role(raw_role = nil)
    role = (raw_role || params.dig(:team_user, :role)).to_s
    INVITABLE_ROLES.include?(role) ? role : nil
  end

  # Only allow a list of trusted parameters through.
  def team_params
    params.require(:team).permit(:name)
  end
end
