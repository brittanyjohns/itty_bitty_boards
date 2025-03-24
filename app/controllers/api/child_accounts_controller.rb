class API::ChildAccountsController < API::ApplicationController
  before_action :set_child_account, only: %i[ show update destroy ]

  # GET /child_accounts
  # GET /child_accounts.json
  def index
    @child_accounts = current_user.child_accounts
    render json: @child_accounts.map(&:index_api_view)
  end

  # GET /child_accounts/1
  # GET /child_accounts/1.json
  def show
    render json: @child_account.api_view(current_user)
  end

  # POST /child_accounts
  # POST /child_accounts.json
  def create
    @child_account = ChildAccount.new(child_account_params)
    parent_id = current_user.id
    username = @child_account.username
    password = params[:password]
    password_confirmation = params[:password_confirmation]
    if password != password_confirmation
      render json: { error: "Passwords do not match" }, status: :unprocessable_entity
      return
    end
    name = @child_account.name
    param_name = params[:name]
    settings = params[:settings]
    if settings
      @child_account.settings = settings
    end
    details = params[:details]
    if details
      @child_account.details = details
    end
    @child_account.user = current_user
    @child_account.passcode = password
    if @child_account.save
      if current_user.professional?
        team = Team.new(name: name, created_by: current_user)
        team.save!
        team.add_member!(current_user, "admin")
        team.add_communicator!(@child_account)
      end
      render json: @child_account.api_view(current_user), status: :created
    else
      puts "Invalid Child Account: errors: #{@child_account.errors.inspect}"
      render json: { errors: @child_account.errors }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /child_accounts/1
  # PATCH/PUT /child_accounts/1.json
  def update
    if params[:password] && params[:password_confirmation]
      if params[:password] != params[:password_confirmation]
        render json: { error: "Passwords do not match" }, status: :unprocessable_entity
        return
      end
      passcode = params[:password]
      @child_account.passcode = passcode unless passcode.blank?
    end
    settings = params[:settings]
    puts "Update Settings: #{settings.inspect}"
    if settings
      @child_account.settings = settings
    end

    details = params[:details]
    if details
      @child_account.details = details
    end

    if @child_account.save
      render json: @child_account.api_view(current_user), status: :ok
    else
      render json: @child_account.errors, status: :unprocessable_entity
    end
  end

  def assign_boards
    @child_account = ChildAccount.find(params[:id])
    board_ids = params[:board_ids]
    if board_ids
      all_records_saved = nil
      board_ids.each do |board_id|
        board = Board.find(board_id)
        if @child_account.child_boards.where(board_id: board.id).empty?
          comm_board = @child_account.child_boards.create!(board: board, created_by: current_user)
          all_records_saved = comm_board.persisted?
        else
          all_records_saved = false
          break
        end
      end
      if all_records_saved
        render json: @child_account.api_view(current_user), status: :ok
      else
        render json: @comm_board.errors, status: :unprocessable_entity
      end
    else
      render json: { error: "No board_ids provided" }, status: :unprocessable_entity
    end
  end

  # DELETE /child_accounts/1
  # DELETE /child_accounts/1.json
  def destroy
    unless @child_account.user == current_user || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
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
    params.require(:child_account).permit(:user_id, :username, :nickname, :name)
  end
end
