class TeamBoardsController < ApplicationController
  before_action :set_team_board, only: %i[ show edit update destroy ]

  # GET /team_boards or /team_boards.json
  def index
    @team_boards = TeamBoard.all
  end

  # GET /team_boards/1 or /team_boards/1.json
  def show
    @board = @team_board.board
    @team = @team_board.team
    @display_for = @board.user
  end

  # GET /team_boards/new
  def new
    @team = Team.find(params[:team_id]) if params[:team_id]
    @boards = current_user.boards.excluding(@team.boards).order(:name)
    @team_board = @team.team_boards.new
  end

  # GET /team_boards/1/edit
  def edit
  end

  # POST /team_boards or /team_boards.json
  def create
    @team = Team.find(team_board_params[:team_id]) if team_board_params[:team_id]
    @board = Board.find(team_board_params[:board_id]) if team_board_params[:board_id]
    @team_board = @team.add_board!(@board)

    respond_to do |format|
      if @team_board.save
        format.html { redirect_to team_board_url(@team_board), notice: "Team board was successfully created." }
        format.json { render :show, status: :created, location: @team_board }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @team_board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /team_boards/1 or /team_boards/1.json
  def update
    respond_to do |format|
      if @team_board.update(team_board_params)
        format.html { redirect_to team_board_url(@team_board), notice: "Team board was successfully updated." }
        format.json { render :show, status: :ok, location: @team_board }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @team_board.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /team_boards/1 or /team_boards/1.json
  def destroy
    @team_board.destroy!

    respond_to do |format|
      format.html { redirect_to team_boards_url, notice: "Team board was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_team_board
      @team_board = TeamBoard.find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def team_board_params
      params.require(:team_board).permit(:board_id, :team_id, :allow_edit)
    end
end
