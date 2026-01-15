class API::TeamsController < API::ApplicationController
  before_action :set_team, only: %i[ show edit update destroy remove_board invite ]
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
    user_role = team_user_params[:role]
    @team = Team.find(params[:id])
    # @user = User.find_by(email: user_email)
    # if @user
    #   Rails.logger.info "Inviting existing user #{@user.id} to team #{@team.id}"
    #   @user.invite_to_team!(@team, current_user, user_role)
    # else
    @user = User.invite_new_user_to_team!(user_email, current_user, @team, user_role)
    #   Rails.logger.info "Inviting new user #{@user.id} to team #{@team.id}"
    #   # @user = User.create_from_email(user_email, nil, current_user.id)
    # end
    # @user = User.find_by(email: user_email) unless @user && @user.persisted?
    unless @user
      return render json: { error: "User not invited. Something went wrong." }, status: :unprocessable_entity
    end
    @team_user = @team.add_member!(@user, user_role) if @user

    respond_to do |format|
      if @team_user.save
        format.json { render json: @team.show_api_view(current_user), status: :created }
      else
        format.json { render json: @team_user.errors, status: :unprocessable_entity }
      end
    end
  end

  def remove_member
    @team = Team.find(params[:id])
    @user = User.find_by(email: params[:email])
    @team_user = TeamUser.find_by(user_id: @user.id, team_id: @team.id)
    @team_user.destroy!
    render json: @team.show_api_view(current_user)
  end

  # POST /teams or /teams.json
  def create
    @team = Team.new
    # @team.name = team_params[:name]&.upcase
    @team.name = team_params[:name]
    account_id = team_params[:account_id]
    @team.created_by = current_user
    Rails.logger.info("Creating team with name: #{@team.name}, created_by: #{current_user.id}, account_id: #{account_id}")

    respond_to do |format|
      if @team.save
        @team.add_member!(current_user, "admin")
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
    @team = Team.find(params[:id])
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

  # Use callbacks to share common setup or constraints between actions.
  def set_team
    # @team = policy_scope(Team).find(params[:id])
    @team = Team.with_artifacts.find(params[:id])
  end

  def team_user_params
    params.require(:team_user).permit(:email, :role)
  end

  # Only allow a list of trusted parameters through.
  def team_params
    params.require(:team).permit(:name, :account_id)
  end
end
