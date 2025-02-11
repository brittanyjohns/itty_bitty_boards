class API::TeamAccountsController < API::ApplicationController
  before_action :set_team_account, only: %i[ show update destroy ]
  after_action :verify_policy_scoped, only: :index

  def index
    @team_accounts = policy_scope(TeamAccount)
    render json: @team_accounts.map { |team_account| team_account.index_api_view(current_user) }
  end

  def show
    render json: @team_account.show_api_view(current_user)
  end

  def create
    @team_account = TeamAccount.new
    @team = Team.find(params[:team_id])
    @team_account.team = @team
    @team_account.account = ChildAccount.find(params[:account_id])

    respond_to do |format|
      if @team_account.save
        @team.reload
        format.json { render json: @team.show_api_view, status: :created }
      else
        format.json { render json: @team_account.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /team_accounts/1 or /team_accounts/1.json
  def update
    respond_to do |format|
      if @team_account.update(team_account_params)
        format.html { redirect_to team_account_url(@team_account), notice: "TeamAccount was successfully updated." }
        format.json { render :show, status: :ok, location: @team_account }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @team_account.errors, status: :unprocessable_entity }
      end
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

  # Use callbacks to share common setup or constraints between actions.
  def set_team_account
    @team_account = policy_scope(TeamAccount).find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def team_account_params
    params.require(:team_account).permit(:team_id, :child_account_id)
  end
end
