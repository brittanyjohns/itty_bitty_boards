class API::TeamsController < API::ApplicationController
  before_action :set_team, only: %i[ show edit update destroy add_board remove_board invite ]
  after_action :verify_policy_scoped, only: :index

  # GET /teams or /teams.json
  def index
    @teams = policy_scope(Team)
    render json: @teams.map { |team| team.index_api_view(current_user) }
  end

  # GET /teams/1 or /teams/1.json
  def show
    @team_user = TeamUser.new
    @team_creator = @team.created_by
    render json: @team.show_api_view(current_user)
  end

  def remaining_boards
    @team = Team.find(params[:id])
    board_ids = @team.boards.pluck(:id)
    puts "Board IDs: #{board_ids}"
    @boards = current_user.boards.where.not(id: board_ids).alphabetical
    puts "Remaining Boards: #{@boards.pluck(:id)}"

    render json: @boards
  end

  def unassigned_accounts
    @team = Team.find(params[:id])
    user_accounts = current_user.child_accounts
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
    @user = User.find_by(email: user_email)
    begin
      puts "Inviting user to team: #{user_email} with role: #{user_role}"
      if @user
        puts ">>User found: #{@user}"
        @user.invite_to_team!(@team, current_user)
      else
        # @user = User.invite!({ email: user_email }, current_user)
        puts ">>Inviting new user to team: #{user_email}"
        @user = current_user.invite_new_user_to_team!(user_email, @team, current_user)
      end
      @user = User.find_by(email: user_email)
      unless @user
        puts "User not found"
        return render json: { error: "User not found" }, status: :unprocessable_entity
      end
      puts "User INVITED: #{@user.email} to team: #{@team}"
      @team_user = @team.add_member!(@user, user_role) if @user
    rescue StandardError => e
      puts "Error: #{e}"
    end
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
    @team.created_by = current_user

    respond_to do |format|
      if @team.save
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

  def add_board
    # @team = Team.find(params[:id])
    @board = Board.find(params[:board_id])
    @team.add_board!(@board)
  end

  def create_board
    @team = Team.find(params[:id])
    @board = Board.find(params[:board_id])
    @team_board = @team.add_board!(@board)
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
    @team = policy_scope(Team).find(params[:id])
  end

  def team_user_params
    params.require(:team_user).permit(:email, :role)
  end

  # Only allow a list of trusted parameters through.
  def team_params
    params.require(:team).permit(:name)
  end
end
