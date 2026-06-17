class API::ChildAccountsController < API::ApplicationController
  before_action :set_child_account, only: %i[ show update destroy promote_to_loaner lend claim_link send_claim_link end_loan archive unarchive assign_boards send_setup_email ]
  before_action :authorize_communicator_edit!, only: %i[ update assign_boards send_setup_email ]
  # Claim preview is the parent's "this is what you're about to claim"
  # page — they may not be signed in yet, so it runs token-only.
  skip_before_action :authenticate_token!, only: %i[ claim_preview ]

  # GET /child_accounts
  # GET /child_accounts.json
  #
  # `?archived=true` returns the caller's soft-archived sandboxes (issue
  # #165). Default scope hides archived rows; the `.archived` scope
  # unscopes `archived_at` and filters to non-null. Without the param,
  # behavior is unchanged.
  def index
    scope = ChildAccount.with_boards.where(user_id: current_user.id)
    scope = scope.archived if ActiveModel::Type::Boolean.new.cast(params[:archived])
    @child_accounts = scope.order(name: :asc)
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
      render json: account_error_payload("Unauthorized"), status: :unauthorized
      return
    end

    unless @child_account.sandbox?
      render json: account_error_payload("Only sandbox communicators can be promoted to loaner"), status: :unprocessable_content
      return
    end

    allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
      user: @child_account.owner,
      status: ChildAccount::LOANER,
    )

    unless allowed
      render json: account_error_payload(error), status: http_status
      return
    end

    begin
      @child_account.promote_to_loaner!(passcode: params[:passcode])
      render json: @child_account.api_view(current_user), status: :ok
    rescue ActiveRecord::RecordInvalid => e
      render json: account_error_payload(e.record.errors.full_messages.join(", ")), status: :unprocessable_content
    end
  end

  # POST /api/child_accounts/:id/lend
  # SLP-facing "Lend to a family" action. Promotes the sandbox to loaner
  # (provisioning a passcode) and issues the claim token in one round
  # trip so the frontend immediately sees `claim_url` on the returned
  # account. Idempotent on a loaner — just rotates the claim token.
  #
  # Error responses always include the current account view so the
  # frontend's "replace state with response" pattern doesn't blow away
  # the status field and flip the UI into a misleading state.
  def lend
    # Ownership guard. By the time we pass this, the caller IS the
    # current owner — which means a `status: active` here is a
    # self-created active (not a family-claimed one). #164 lets the
    # SLP lend it out (passcode gets rotated in promote_to_loaner!).
    unless @child_account.owner_id == current_user.id || current_user.admin?
      if @child_account.active?
        render json: account_error_payload("This communicator is owned by someone else and can't be lent."),
               status: :unprocessable_content
      else
        render json: account_error_payload("Unauthorized"), status: :unauthorized
      end
      return
    end

    # Slot check — only meaningful when the account isn't already in
    # the slot pool (sandbox). Loaners already count; active → loaner
    # is a net-zero change to the slot count.
    if @child_account.sandbox?
      allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
        user: @child_account.owner,
        status: ChildAccount::LOANER,
      )
      unless allowed
        Rails.logger.warn(
          "[lend] denied for user=#{@child_account.owner_id} child_account=#{@child_account.id} " \
          "plan_type=#{@child_account.owner&.plan_type.inspect} " \
          "paid_limit=#{@child_account.owner&.settings&.dig("paid_communicator_limit").inspect} " \
          "owned_slots=#{@child_account.owner ? Permissions::CommunicatorLimits.owned_slot_count(@child_account.owner) : "?"} " \
          "reason=#{error}"
        )
        render json: account_error_payload(error), status: http_status
        return
      end
    end

    begin
      @child_account.promote_to_loaner!(passcode: params[:passcode]) unless @child_account.loaner?
      @child_account.generate_claim_token!
      render json: @child_account.api_view(current_user), status: :ok
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn "[lend] validation failed for child_account=#{@child_account.id}: #{e.record.errors.full_messages.join(", ")}"
      render json: account_error_payload(e.record.errors.full_messages.join(", ")), status: :unprocessable_content
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
      render json: { error: "Only loaners can issue a claim link" }, status: :unprocessable_content
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
      render json: account_error_payload("Unauthorized"), status: :unauthorized
      return
    end

    unless @child_account.loaner?
      render json: account_error_payload("Only loaners can issue a claim link"), status: :unprocessable_content
      return
    end

    email = params[:email].to_s.strip
    if email.blank? || !email.include?("@")
      render json: account_error_payload("A valid email is required"), status: :unprocessable_content
      return
    end

    @child_account.generate_claim_token! if @child_account.claim_token.blank?

    begin
      CommunicationAccountMailer.claim_link_email(@child_account, email, current_user).deliver_later
    rescue => e
      Rails.logger.error "[send_claim_link] mailer failed for child_account=#{@child_account.id}: #{e.message}"
      render json: account_error_payload("Couldn't send the email. Please try again."), status: :service_unavailable
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
      }, status: :unprocessable_content
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
    end
  end

  # POST /api/child_accounts/:id/end_loan
  # SLP ends the loan immediately (B5). Returns the slot.
  def end_loan
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: account_error_payload("Unauthorized"), status: :unauthorized
      return
    end

    unless @child_account.loaner?
      render json: account_error_payload("Only loaners can be reclaimed"), status: :unprocessable_content
      return
    end

    @child_account.reclaim!(reason: "manual")
    render json: @child_account.api_view(current_user), status: :ok
  end

  # POST /api/child_accounts/:id/archive
  # Soft-archive a communicator (issues #165, #237). The record stays in
  # the database with all its boards/settings/history — it just drops out
  # of the default-scoped lists. Allowed for sandbox and owner-controlled
  # active. Loaner is excluded — use end_loan first to clear the claim
  # token and slot accounting.
  def archive
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: account_error_payload("Unauthorized"), status: :unauthorized
      return
    end

    if @child_account.loaner?
      render json: account_error_payload("End the loan first via end_loan."), status: :unprocessable_content
      return
    end

    @child_account.archive!(reason: "owner_request")
    render json: @child_account.api_view(current_user), status: :ok
  end

  # POST /api/child_accounts/:id/unarchive
  # Restore a previously-archived communicator. Sandbox restores as a
  # sandbox; active restores as active, but only if the owner still has
  # a free slot (archiving freed it, and the owner may have filled it).
  def unarchive
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: account_error_payload("Unauthorized"), status: :unauthorized
      return
    end

    @child_account.unarchive!
    render json: @child_account.api_view(current_user), status: :ok
  rescue ChildAccount::SlotFull => e
    render json: account_error_payload(e.message.presence || "At your communicator slot limit. Free a slot before restoring."),
           status: :unprocessable_content
  end

  # POST /child_accounts
  def create
    is_demo = params[:is_demo] ? ActiveModel::Type::Boolean.new.cast(params[:is_demo]) : false
    # Prefer the explicit lifecycle status param; fall back to legacy is_demo.
    requested_status = params[:status].presence || (is_demo ? ChildAccount::SANDBOX : ChildAccount::ACTIVE)
    # A Free user never self-creates a full communicator — every self-create is a
    # no-login sandbox "MySpeak Free account" (full login is claim/hand-off only).
    requested_status = Permissions::CommunicatorLimits.self_create_status(
      user: current_user,
      requested: requested_status,
    )

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

    # Passcode is required for loaner/active; sandbox accounts have no
    # login. Assign before validation runs — the B3
    # `loaner_or_active_must_have_login` validation will otherwise trip
    # on every non-sandbox create.
    password = params[:password]
    password_confirmation = params[:password_confirmation]

    if password.present? && password_confirmation.present? && password != password_confirmation
      render json: { error: "Passwords do not match" }, status: :unprocessable_content
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
          render json: { error: "Error creating profile for child account: #{e.message}" }, status: :unprocessable_content
          return
        end
      end

      # Team setup. `ensure_team!` adds the creator as admin; no
      # follow-up call needed (issue #226).
      team_name = @child_account.name.present? ?
        "#{@child_account.name}'s Communication Team" :
        "Communication Team"
      @child_account.ensure_team!(creator: current_user, name: team_name)

      render json: @child_account.api_view(current_user), status: :created
    else
      Rails.logger.info "Invalid Child Account: errors: #{@child_account.errors.inspect}"
      message = @child_account.errors.full_messages.join(", ")
      render json: { error: message, errors: message }, status: :unprocessable_content
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
      # A Free user can't self-promote a sandbox into a full communicator
      # (claim/hand-off only) — keep it a sandbox. Paid plans may promote, so
      # re-check slot limits. Only the sandbox→active path is touched here, so
      # an existing claimed/active communicator is never demoted.
      requested_status = Permissions::CommunicatorLimits.self_create_status(
        user: current_user,
        requested: requested_status,
      )
      @child_account.status = requested_status

      if requested_status != ChildAccount::SANDBOX
        allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
          user: current_user,
          status: requested_status,
        )

        unless allowed
          render json: { error: error }, status: http_status
          return
        end
      end
    end

    if params[:password] && params[:password_confirmation]
      if params[:password] != params[:password_confirmation]
        render json: { error: "Passwords do not match" }, status: :unprocessable_content
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
      message = @child_account.errors.full_messages.join(", ")
      render json: account_error_payload(message), status: :unprocessable_content
    end
  end

  def assign_boards
    board_ids = params[:board_ids]
    if board_ids.blank?
      render json: { error: "No board_ids provided" }, status: :unprocessable_content
      return
    end

    # Normalize a single id (String/Integer) to an array *before* counting,
    # so the sandbox limit check below counts boards — not the characters of
    # a bare string id (e.g. "123".size == 3 would corrupt the cap check).
    board_ids = Array(board_ids).map(&:to_i)

    total_boards = @child_account.child_boards.count + board_ids.size
    if @child_account.sandbox?
      demo_limit = (@child_account.settings["demo_board_limit"] || ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT).to_i
      if total_boards > demo_limit
        render json: { error: "Demo board limit exceeded. You can have up to #{demo_limit} boards." }, status: :unprocessable_content
        return
      end
    end

    board_ids.each do |board_id|
      board = Board.find(board_id)
      voice = @child_account.voice || "polly:kevin"
      board.clone_with_images(current_user&.id, board.name, voice, @child_account)
    end
    render json: @child_account.api_view(current_user), status: :ok
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
  # `with_archived` so unarchive (and admin maintenance) can target a
  # soft-archived record — the default scope hides them otherwise.
  def set_child_account
    @parent_account = current_user
    @child_account = ChildAccount.with_archived.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def child_account_params
    params.require(:child_account).permit(:user_id, :username, :name)
  end

  # Issues #210 / #211 — content-mutating endpoints on the communicator
  # itself (name, username, passcode, voice, settings, layout, boards
  # roster, setup email) must be owner-only. SLP supervisors and other
  # team members are read-only on the communicator object; they share
  # boards via the team instead. System admins bypass.
  #
  # The inline ownership checks in `lend`, `end_loan`, `archive`,
  # `unarchive`, `promote_to_loaner`, `claim_link`, and `send_claim_link`
  # haven't been folded in here yet — each has its own error message /
  # status nuance. Tracked as a follow-up.
  def authorize_communicator_edit!
    return if @child_account.editable_by?(current_user)

    render json: account_error_payload("not_owner").merge(
      message: "Only the owner can edit this communicator.",
    ), status: :forbidden
  end

  # Mutation endpoints (lend, end_loan, etc.) return the current account
  # view in error responses so a frontend that does
  # `setState(response)` doesn't lose the status / is_demo fields and
  # flip into the wrong UI state. The error message is included as a
  # sibling field so callers that DO check can still surface it.
  def account_error_payload(error)
    view = @child_account ? @child_account.reload.api_view(current_user) : {}
    view.merge(error: error.to_s, errors: error.to_s)
  end
end
