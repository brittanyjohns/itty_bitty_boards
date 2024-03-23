class TeamsController < ApplicationController
  before_action :authenticate_user!, except: %i[ accept_invite ]
  before_action :set_team, only: %i[ show edit update destroy add_board remove_board ]
  after_action :verify_policy_scoped, only: :index

  # GET /teams or /teams.json
  def index
    @teams = policy_scope(Team)
  end

  # GET /teams/1 or /teams/1.json
  def show
    @team_user = TeamUser.new
  end

  def set_current
    @team = policy_scope(Team).find(params[:team_id])
    

    respond_to do |format|
      if current_user.update(current_team: @team)
        format.html { redirect_to team_url(@team), notice: "Your current team has been set to: #{current_user.current_team&.name}. You can change this at any time from your profile page." }
        format.json { render :show, status: :ok, location: @team }
      else
        format.html { render :show, status: :unprocessable_entity }
        format.json { render json: current_user.errors, status: :unprocessable_entity }
      end
    end

  end

  # GET /teams/new
  def new
    @team = Team.new
  end

  # GET /teams/1/edit
  def edit
  end

  def invite
    puts "team_board_params: #{team_user_params.inspect}"
    user_email = team_user_params[:email]
    user_role = team_user_params[:role]
    @team = Team.find(params[:id])
    @user = User.find_by(email: user_email)
    if @user
      @user.invite_to_team!(@team, current_user)
    else
      puts "User not found"
      @user = User.invite!({ email: user_email }, current_user)
    end
    puts "role: #{user_role}"
    
    @team_user = @team.add_member!(@user, user_role)
    puts "Team User: #{@team_user.inspect}"
    respond_to do |format|
      if @team_user.save
        format.html { redirect_to team_url(@team), notice: "Sent invite to #{user_email}" }
        format.json { render :show, status: :created, location: @team }
      else
        format.html { render :show, status: :unprocessable_entity }
        format.json { render json: @team_user.errors, status: :unprocessable_entity }
      end
    end
  end

  # POST /teams or /teams.json
  def create
    @team = Team.new
    @team.name = team_params[:name]&.upcase
    @team.created_by = current_user

    respond_to do |format|
      if @team.save
        format.html { redirect_to team_url(@team), notice: "Team was successfully created." }
        format.json { render :show, status: :created, location: @team }
      else
        format.html { render :new, status: :unprocessable_entity }
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
    redirect_to team_url(@team)
  end

  def add_board
    # @team = Team.find(params[:id])
    @board = Board.find(params[:board_id])
    @team.add_board!(@board)
    redirect_to team_url(@team), notice: "Board added to team"
  end

  def remove_board
    # @team = Team.find(params[:id])
    @board = Board.find(params[:board_id])
    @team.remove_board!(@board)
    redirect_to team_url(@team), notice: "Board removed from team"
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
      format.html { redirect_to teams_url, notice: "Team was successfully destroyed." }
      format.json { head :no_content }
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
