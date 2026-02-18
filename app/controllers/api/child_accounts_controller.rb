class API::ChildAccountsController < API::ApplicationController
  before_action :set_child_account, only: %i[ show update destroy ]

  # GET /child_accounts
  # GET /child_accounts.json
  def index
    @child_accounts = ChildAccount.with_boards.where(user_id: current_user.id)
    render json: @child_accounts.map(&:index_api_view)
  end

  # GET /child_accounts/1
  # GET /child_accounts/1.json
  def show
    if @child_account.vendor?
      render json: @child_account.vendor_api_view(current_user)
      return
    end
    render json: @child_account.api_view(current_user)
  end

  def send_setup_email
    @child_account = ChildAccount.find(params[:id])
    @child_account.send_setup_email(current_user)
    render json: { success: true }
  end

  # POST /child_accounts
  def create
    is_demo = params[:is_demo] ? ActiveModel::Type::Boolean.new.cast(params[:is_demo]) : false
    Rails.logger.info "Creating Child Account - is_demo: #{is_demo}"

    allowed, status, error = Permissions::CommunicatorLimits.can_create?(
      user: current_user,
      is_demo: is_demo,
    )

    unless allowed
      render json: { error: error }, status: status
      return
    end

    @child_account = ChildAccount.new(child_account_params)
    Rails.logger.debug "Child Account Params: #{child_account_params.inspect}"

    # Type + ownership
    @child_account.is_demo = is_demo
    @child_account.owner = current_user
    @child_account.user = current_user if @child_account.respond_to?(:user=) # legacy (optional)

    # Validate basic fields first
    unless @child_account.valid?
      Rails.logger.info "Invalid Child Account: errors: #{@child_account.errors.full_messages.join(", ")}"
      render json: { errors: @child_account.errors.full_messages.join(", ") }, status: :unprocessable_entity
      return
    end

    # Passcode (required)
    password = params[:password]
    password_confirmation = params[:password_confirmation]

    if password != password_confirmation
      render json: { error: "Passwords do not match" }, status: :unprocessable_entity
      return
    end

    @child_account.passcode = password

    # Optional attrs
    @child_account.settings = params[:settings] if params[:settings].present?
    @child_account.details = params[:details] if params[:details].present?

    # Profile linking (existing behavior)
    profile = nil
    if params[:profile_id].present?
      profile = Profile.find(params[:profile_id])
      profile.update!(
        profileable: @child_account,
        placeholder: false,
        claimed_at: Time.current,
        claim_token: nil,
      )
    end

    if @child_account.save
      @child_account.create_profile! unless profile.present?

      # Team setup
      team_name = if @child_account.name.present?
          "#{@child_account.name}'s Communication Team"
        else
          "Communication Team"
        end

      team = @child_account.teams.first
      unless team
        team = Team.create!(name: team_name, created_by: current_user)
        TeamAccount.create!(team: team, account: @child_account)
      end

      team_role = current_user.professional? ? "professional" : "admin"
      team.add_member!(current_user, team_role)

      render json: @child_account.api_view(current_user), status: :created
    else
      Rails.logger.info "Invalid Child Account: errors: #{@child_account.errors.inspect}"
      render json: { errors: @child_account.errors }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /child_accounts/1
  # PATCH/PUT /child_accounts/1.json
  def update
    name = params[:name]
    username = params[:username]
    @child_account.username = username unless username.blank?
    @child_account.name = name unless name.blank?
    was_a_demo = @child_account.is_demo
    is_demo = params[:is_demo] ? ActiveModel::Type::Boolean.new.cast(params[:is_demo]) : false
    @child_account.is_demo = is_demo
    if was_a_demo && !is_demo
      # Changing from demo to paid - check limits
      allowed, status, error = Permissions::CommunicatorLimits.can_create?(
        user: current_user,
        is_demo: is_demo,
      )

      unless allowed
        render json: { error: error }, status: status
        return
      end
    end

    if params[:password] && params[:password_confirmation]
      if params[:password] != params[:password_confirmation]
        render json: { error: "Passwords do not match" }, status: :unprocessable_entity
        return
      end
      passcode = params[:password]
      @child_account.passcode = passcode unless passcode.blank?
    end
    settings = params[:settings]

    voice_name = settings&.dig("voice", "name")
    current_voice = @child_account.voice_settings["name"]
    if voice_name
      if current_voice != voice_name
        @child_account.update_audio(voice_name)
      end
    end

    if settings
      @child_account.settings = settings
    end

    details = params[:details]
    if details
      @child_account.details = details
    end

    if params[:layout]
      @child_account.layout = params[:layout]
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
    total_boards = @child_account.child_boards.count + board_ids.size
    if @child_account.is_demo?
      demo_limit = (@child_account.settings["demo_board_limit"] || ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT).to_i
      if total_boards > demo_limit
        render json: { error: "Demo board limit exceeded. You can have up to #{demo_limit} boards." }, status: :unprocessable_entity
        return
      end
    end
    if board_ids
      board_ids.each do |board_id|
        og_board = Board.find(board_id)
        if og_board.predefined?
          board = og_board.clone_with_images(current_user&.id, og_board.name)
        else
          board = og_board
        end
        voice = @child_account.voice || "polly:kevin"
        child_board_copy = board.clone_with_images(current_user&.id, board.name, voice, @child_account)
      end
      render json: @child_account.api_view(current_user), status: :ok
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
