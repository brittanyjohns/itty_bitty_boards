class API::ChildAccountsController < API::ApplicationController
  before_action :set_child_account, only: %i[ show update destroy promote_to_loaner lend claim_link send_claim_link end_loan ]
  # Claim preview is the parent's "this is what you're about to claim"
  # page — they may not be signed in yet, so it runs token-only.
  skip_before_action :authenticate_token!, only: %i[ claim_preview ]

  # GET /child_accounts
  # GET /child_accounts.json
  def index
    @child_accounts = ChildAccount.with_boards.where(user_id: current_user.id).order(name: :asc)
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

  # POST /api/child_accounts/:id/promote_to_loaner
  # Promotes a sandbox communicator to a loaner: provisions a passcode
  # (caller may supply one), lifts the sandbox board cap, and starts
  # counting against the owner's slot. The owner must be authorized to
  # add a loaner slot (B2 limits).
  def promote_to_loaner
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    unless @child_account.sandbox?
      render json: { error: "Only sandbox communicators can be promoted to loaner" }, status: :unprocessable_entity
      return
    end

    allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
      user: @child_account.owner,
      status: ChildAccount::LOANER,
    )

    unless allowed
      render json: { error: error }, status: http_status
      return
    end

    begin
      @child_account.promote_to_loaner!(passcode: params[:passcode])
      render json: @child_account.api_view(current_user), status: :ok
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # POST /api/child_accounts/:id/lend
  # SLP-facing "Lend to a family" action. Promotes the sandbox to loaner
  # (provisioning a passcode) and issues the claim token in one round
  # trip so the frontend immediately sees `claim_url` on the returned
  # account. Idempotent on a loaner — just rotates the claim token.
  def lend
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    if @child_account.active?
      render json: { error: "This communicator has already been claimed" }, status: :unprocessable_entity
      return
    end

    if @child_account.sandbox?
      allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
        user: @child_account.owner,
        status: ChildAccount::LOANER,
      )
      unless allowed
        render json: { error: error }, status: http_status
        return
      end
    end

    begin
      @child_account.promote_to_loaner!(passcode: params[:passcode]) if @child_account.sandbox?
      @child_account.generate_claim_token!
      render json: @child_account.api_view(current_user), status: :ok
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # POST /api/child_accounts/:id/claim_link
  # SLP-only. Generates (or rotates) the claim token a parent uses to
  # take ownership of this loaner. Returns the URL the SLP shares.
  def claim_link
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    unless @child_account.loaner?
      render json: { error: "Only loaners can issue a claim link" }, status: :unprocessable_entity
      return
    end

    @child_account.generate_claim_token!
    render json: {
      claim_token: @child_account.claim_token,
      claim_url: @child_account.claim_link_url,
      claim_token_sent_at: @child_account.claim_token_sent_at,
    }, status: :ok
  end

  # POST /api/child_accounts/:id/send_claim_link
  # Generates (or rotates) the claim token and emails it to the parent.
  # Owner-only. Body: { email: "parent@example.com" }.
  def send_claim_link
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    unless @child_account.loaner?
      render json: { error: "Only loaners can issue a claim link" }, status: :unprocessable_entity
      return
    end

    email = params[:email].to_s.strip
    if email.blank? || !email.include?("@")
      render json: { error: "A valid email is required" }, status: :unprocessable_entity
      return
    end

    @child_account.generate_claim_token! if @child_account.claim_token.blank?

    begin
      CommunicationAccountMailer.claim_link_email(@child_account, email, current_user).deliver_later
    rescue => e
      Rails.logger.error "[send_claim_link] mailer failed for child_account=#{@child_account.id}: #{e.message}"
      render json: { error: "Couldn't send the email. Please try again." }, status: :service_unavailable
      return
    end

    render json: { ok: true, claim_url: @child_account.claim_link_url, sent_to: email }, status: :ok
  end

  # GET /api/communicator_claims/:token
  # Public preview shown on the parent's claim page before they sign in.
  # Returns a stable shape so the frontend can render expired/claimed
  # states without a separate request.
  def claim_preview
    account = ChildAccount.find_by(claim_token: params[:token])
    if account.nil?
      render json: { error: "Invalid or expired claim link", expired: true }, status: :not_found
      return
    end

    if account.active?
      render json: {
        status: "claimed",
        already_claimed: true,
        owner_name: account.owner&.display_name,
      }, status: :ok
      return
    end

    expired = account.claim_token_sent_at.present? &&
              account.claim_token_sent_at < LoanerReclaimJob::RECLAIM_AFTER.ago

    render json: {
      status: expired ? "expired" : account.status,
      expired: expired,
      already_claimed: false,
      child_name: account.display_name,
      communicator_name: account.display_name,
      owner_name: account.owner&.display_name,
      owner_email: account.owner&.email,
    }, status: :ok
  end

  # POST /api/communicator_claims/:token/claim
  # Parent (signed in) claims the loaner. Transfers ownership, swaps
  # onto the parent's plan, frees the SLP's slot, keeps the SLP on the
  # child's team as a supervisor.
  #
  # Response is wrapped as `{ account: ..., error: ... }` so the
  # frontend can branch on `result.error` regardless of HTTP status.
  def claim
    account = ChildAccount.find_by(claim_token: params[:token])
    unless account&.loaner?
      render json: { error: "Invalid or expired claim link" }, status: :not_found
      return
    end

    begin
      account.claim_by!(user: current_user)
      render json: { account: account.api_view(current_user) }, status: :ok
    rescue ChildAccount::SlotFull => e
      render json: {
        error: "slot_full",
        message: e.message,
        upgrade_url: "/account/billing/upgrade",
      }, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end

  # POST /api/child_accounts/:id/end_loan
  # SLP ends the loan immediately (B5). Returns the slot.
  def end_loan
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    unless @child_account.loaner?
      render json: { error: "Only loaners can be reclaimed" }, status: :unprocessable_entity
      return
    end

    @child_account.reclaim!(reason: "manual")
    render json: @child_account.api_view(current_user), status: :ok
  end

  # POST /child_accounts
  def create
    is_demo = params[:is_demo] ? ActiveModel::Type::Boolean.new.cast(params[:is_demo]) : false
    # Prefer the explicit lifecycle status param; fall back to legacy is_demo.
    requested_status = params[:status].presence || (is_demo ? ChildAccount::SANDBOX : ChildAccount::ACTIVE)

    allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
      user: current_user,
      status: requested_status,
    )

    unless allowed
      render json: { error: error }, status: http_status
      return
    end
    username = params[:username]
    name = params[:name]
    nickname = params[:nickname]

    @child_account = ChildAccount.new(username: username, name: name, status: requested_status)

    # Ownership
    @child_account.owner = current_user
    @child_account.user = current_user if @child_account.respond_to?(:user=) # legacy (optional)

    # Validate basic fields first
    unless @child_account.valid?
      render json: { errors: @child_account.errors.full_messages.join(", ") }, status: :unprocessable_entity
      return
    end

    # Passcode is required for loaner/active; sandbox accounts have no login.
    password = params[:password]
    password_confirmation = params[:password_confirmation]

    if password != password_confirmation
      render json: { error: "Passwords do not match" }, status: :unprocessable_entity
      return
    end

    @child_account.passcode = password if password.present? && requested_status != ChildAccount::SANDBOX

    # Optional attrs
    @child_account.settings = params[:settings] if params[:settings].present?
    @child_account.details = params[:details] if params[:details].present?

    # A Free user's sandbox communicator is capped at one board; Pro sandbox
    # accounts fall through to ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT.
    if requested_status == ChildAccount::SANDBOX && current_user.free?
      @child_account.settings ||= {}
      @child_account.settings["demo_board_limit"] = ChildAccount::FREE_DEMO_BOARD_LIMIT
    end

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
      unless profile.present?
        begin
          @child_account.create_profile!
        rescue => e
          Rails.logger.error "Failed to create profile for ChildAccount #{@child_account.id}: #{e.message}"
          render json: { error: "Error creating profile for child account: #{e.message}" }, status: :unprocessable_entity
          return
        end
      end

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
    was_sandbox = @child_account.sandbox?
    is_demo = params[:is_demo] ? ActiveModel::Type::Boolean.new.cast(params[:is_demo]) : false
    requested_status = params[:status].presence || (is_demo ? ChildAccount::SANDBOX : ChildAccount::ACTIVE)
    @child_account.status = requested_status
    if was_sandbox && requested_status != ChildAccount::SANDBOX
      # Promoting sandbox → loaner/active — re-check slot limits.
      allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
        user: current_user,
        status: requested_status,
      )

      unless allowed
        render json: { error: error }, status: http_status
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
    if @child_account.sandbox?
      demo_limit = (@child_account.settings["demo_board_limit"] || ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT).to_i
      if total_boards > demo_limit
        render json: { error: "Demo board limit exceeded. You can have up to #{demo_limit} boards." }, status: :unprocessable_entity
        return
      end
    end
    if board_ids
      if board_ids.is_a?(String) || board_ids.is_a?(Integer)
        board_ids = [board_ids.to_i]
      end
      board_ids.each do |board_id|
        board = Board.find(board_id)
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
    params.require(:child_account).permit(:user_id, :username, :name)
  end
end
