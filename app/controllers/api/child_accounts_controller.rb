class API::ChildAccountsController < API::ApplicationController
  before_action :set_child_account, only: %i[ show update destroy ]

  # GET /child_accounts
  # GET /child_accounts.json
  def index
    @child_accounts = current_user.child_accounts
    render json: @child_accounts.map(&:api_view)
  end

  # GET /child_accounts/1
  # GET /child_accounts/1.json
  def show
    render json: @child_account.api_view
  end

  # POST /child_accounts
  # POST /child_accounts.json
  def create
    @child_account = ChildAccount.new(child_account_params)
    parent_id = current_user.id
    username = @child_account.username
    password = params[:password]
    @child_account.user = current_user
    @child_account.password = password
    @child_account.password_confirmation = password
    if @child_account.save
      puts "Valid Child Account: valid_credentials? #{ChildAccount.valid_credentials?(parent_id, username, password)}"
      render json: @child_account.api_view, status: :created
    else
      render json: @child_account.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /child_accounts/1
  # PATCH/PUT /child_accounts/1.json
  def update
    if @child_account.update(child_account_params)
      render json: @child_account.api_view, status: :ok
    else
      render json: @child_account.errors, status: :unprocessable_entity
    end
  end

  def assign_board
    @child_account = ChildAccount.find(params[:id])
    @board = Board.find(params[:board_id])
    if @child_account.child_boards.where(board_id: @board.id).empty?
      if @child_account.child_boards.create!(board: @board)
        render json: @child_account.api_view, status: :ok
      else
        render json: @child_account.errors, status: :unprocessable_entity
      end
    else
      render json: { error: "Board already assigned" }, status: :unprocessable_entity
    end
  end

  # DELETE /child_accounts/1
  # DELETE /child_accounts/1.json
  def destroy
    @child_account.destroy!
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_child_account
    @parent_account = current_user
    @child_account = ChildAccount.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def child_account_params
    params.require(:child_account).permit(:user_id, :username, :nickname)
  end
end
