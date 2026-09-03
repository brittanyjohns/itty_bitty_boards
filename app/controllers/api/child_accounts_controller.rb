class API::ChildAccountsController < API::ApplicationController
  before_action :set_child_account, only: %i[ show update destroy promote_to_loaner lend claim_link send_claim_link end_loan archive unarchive assign_boards send_setup_email ]
  # Editing the communicator object (name/username/voice/settings) and the
  # setup email stay owner-only. Assigning boards to the dashboard is a
  # curation action, so it uses the looser curate gate below (supervisors
  # and admins can assign, matching `can_edit` in the serializer).
  before_action :authorize_communicator_edit!, only: %i[ update send_setup_email ]
  before_action :authorize_communicator_curate!, only: %i[ assign_boards ]
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
    if ActiveModel::Type::Boolean.new.cast(params[:handed_off])
      # Communicators this user handed off to a family: they were claimed
      # (claimed_at set) and the user stayed on the team as a supervisor, but
      # no longer owns them. There's no previous_owner_id column — supervisor +
      # claimed + not-owner is the canonical hand-off fingerprint (claim_by!
      # demotes the previous owner to supervisor). distinct because a user may
      # sit on more than one of the communicator's teams.
      scope = ChildAccount.with_boards
        .joins(:team_users)
        .where(team_users: { user_id: current_user.id, role: "supervisor" })
        .where.not(owner_id: current_user.id)
        .where.not(claimed_at: nil)
        .distinct
    else
      # Scope on owner_id — the canonical ownership column that slot counts,
      # serializers, and every other action use. (user_id is the legacy parent
      # mirror; scoping on it could diverge from the "X of Y" counts.) A loaner
      # keeps owner_id = the lender, so it stays listed until a family claims it.
      scope = ChildAccount.with_boards.where(owner_id: current_user.id)
      scope = scope.archived if ActiveModel::Type::Boolean.new.cast(params[:archived])
    end
    @child_accounts = scope.order(name: :asc)
    render json: @child_accounts.map(&:index_api_view)
  end

  # POST /child_accounts/keep_signable
  #
  # Owner picks which communicators stay signable when over the plan's slot
  # limit (issue #439) — the mirror of the board "make_editable" pick. The
  # chosen ids keep private sign-in; the rest enter fallback mode (public
  # MySpeak page stays open and read-only). Owner-scoped: ids the caller
  # doesn't own are ignored, and the set is capped at the plan slot limit.
  def keep_signable
    kept = current_user.set_kept_communicator_ids!(params[:communicator_ids])
    accounts = current_user.slotted_communicator_accounts.order(name: :asc)
    render json: {
      kept_communicator_ids: kept,
      communicator_slot_limit: Permissions::CommunicatorLimits.slot_limit_for(current_user.settings || {}),
      communicators: accounts.map(&:index_api_view),
    }
  end

  # GET /api/child_accounts/username_available?username=leo
  #
  # Communicator usernames are globally unique (`validates :username,
  # uniqueness: true` + a plain unique index), so every common first name is
  # already someone's. A parent naming their child "Leo" used to learn that
  # only from a 422 at the end of the create — at the exact moment of
  # activation, on the least technical user we have. This lets the form ask
  # first.
  #
  # The answer is about the NORMALIZED name, which is what the client should
  # submit: `username` echoes back what was actually checked, and the create
  # path derives the same shape via `name.parameterize` when no username is
  # sent.
  #
  # Enumeration: this does reveal whether an arbitrary username exists.
  # Requiring a signed-in caller is the mitigation, backed by a per-caller
  # Rack::Attack throttle; nothing about the OWNER of a taken name is
  # returned, only that it is taken.
  def username_available
    raw = normalized_username(params[:username])

    if raw.blank?
      render json: { username: "", available: false, suggestions: [] }
      return
    end

    taken = ChildAccount.exists?(username: raw)
    render json: {
      username: raw,
      available: !taken,
      suggestions: taken ? username_suggestions(raw) : [],
    }
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

    return unless require_pro_for_lending!

    unless @child_account.sandbox?
      render json: account_error_payload("Only sandbox communicators can be promoted to loaner"), status: :unprocessable_content
      return
    end

    allowed, http_status, error, error_code = Permissions::CommunicatorLimits.can_create?(
      user: @child_account.owner,
      status: ChildAccount::LOANER,
    )

    unless allowed
      render json: account_error_payload(error).merge(
        slot_limit_details(@child_account.owner, ChildAccount::LOANER, error_code),
      ), status: http_status
      return
    end

    begin
      @child_account.promote_to_loaner!(passcode: params[:passcode])
      render json: @child_account.api_view(current_user), status: :ok
    rescue ActiveRecord::RecordInvalid => e
      render json: account_error_payload(e.record.errors.full_messages.join(", "), record: e.record), status: :unprocessable_content
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

    return unless require_pro_for_lending!

    # Slot check — only meaningful when the account isn't already in
    # the slot pool (sandbox). Loaners already count; active → loaner
    # is a net-zero change to the slot count.
    if @child_account.sandbox?
      allowed, http_status, error, error_code = Permissions::CommunicatorLimits.can_create?(
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
        render json: account_error_payload(error).merge(
          slot_limit_details(@child_account.owner, ChildAccount::LOANER, error_code),
        ), status: http_status
        return
      end
    end

    begin
      @child_account.promote_to_loaner!(passcode: params[:passcode]) unless @child_account.loaner?
      # Deliberately rotates every time. "Lend" is the explicit action, and
      # re-lending is how an SLP revokes a link that went to the wrong person.
      # #claim_link — a read action the panel calls just to show the URL — is
      # the one that must NOT rotate.
      @child_account.generate_claim_token!
      render json: @child_account.api_view(current_user), status: :ok
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn "[lend] validation failed for child_account=#{@child_account.id}: #{e.record.errors.full_messages.join(", ")}"
      render json: account_error_payload(e.record.errors.full_messages.join(", "), record: e.record), status: :unprocessable_content
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

    # Reuse an existing token by default. This action used to rotate on every
    # call, so an SLP who emailed a claim link and then reopened the Lend panel
    # silently killed the link the family was holding. `rotate=true` is the
    # deliberate regenerate.
    rotate = ActiveModel::Type::Boolean.new.cast(params[:rotate]) == true
    @child_account.generate_claim_token! if rotate || @child_account.claim_token.blank?

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

    # Refuse rather than email a link nobody can open. The app UI can rebuild a
    # localhost claim_url against window.location.origin; an email cannot, and a
    # dead claim link is worse than a retry prompt.
    # Only enforced where a localhost link is actually wrong. In development and
    # test, localhost IS the front end.
    if Rails.env.production? && !ChildAccount.front_end_base_url_sendable?
      Rails.logger.error "[send_claim_link] refusing to email a localhost claim link for child_account=#{@child_account.id} — set FRONT_END_URL"
      render json: account_error_payload("Couldn't send the email. Please try again."), status: :service_unavailable
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

    allowed, http_status, error, error_code = Permissions::CommunicatorLimits.can_create?(
      user: current_user,
      status: requested_status,
    )

    unless allowed
      Analytics::CommunicatorEvents.slot_limit_reached(
        user: current_user,
        status: requested_status,
        source: Analytics::CommunicatorEvents::CHILD_ACCOUNTS,
      )
      render json: { error: error }.merge(
        slot_limit_details(current_user, requested_status, error_code),
      ), status: http_status
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
    @child_account.settings = normalized_settings(params[:settings]) if params[:settings].present?
    @child_account.details = params[:details] if params[:details].present?
    apply_top_level_aac_profile_params!(@child_account)

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
      minted_profile = nil
      unless profile.present?
        begin
          minted_profile = @child_account.create_profile!
        rescue => e
          Rails.logger.error "Failed to create profile for ChildAccount #{@child_account.id}: #{e.message}"
          render json: { error: "Error creating profile for child account: #{e.message}" }, status: :unprocessable_content
          return
        end
      end

      Analytics::CommunicatorEvents.account_created(
        user: current_user,
        child: @child_account,
        source: Analytics::CommunicatorEvents::CHILD_ACCOUNTS,
      )
      # The auto-minted MySpeak page. Only reported when this request actually
      # created it — a `profile_id` hand-off is a claim, not a new page.
      if minted_profile
        Analytics::CommunicatorEvents.myspeak_page_created(
          user: current_user,
          profile: minted_profile,
          child: @child_account,
          source: Analytics::CommunicatorEvents::CHILD_ACCOUNTS,
        )
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
      # `field_errors` is ADDITIVE — `error` and `errors` keep the flat string
      # the current frontend reads, so the two repos ship in either order. It
      # is what lets a taken username be shown on the username input rather
      # than as one sentence at the bottom of the form.
      render json: {
        error: message,
        errors: message,
        field_errors: field_errors_for(@child_account),
      }, status: :unprocessable_content
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
        allowed, http_status, error, error_code = Permissions::CommunicatorLimits.can_create?(
          user: current_user,
          status: requested_status,
        )

        unless allowed
          render json: { error: error }.merge(
            slot_limit_details(current_user, requested_status, error_code),
          ), status: http_status
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
      # MERGE, don't replace. Each frontend tab saves its own slice of this
      # blob as a fresh literal, so a wholesale assignment silently dropped
      # every key that tab doesn't know about — the dashboard layout columns,
      # primary_team_id, archive/reclaim/fallback state, demo_board_limit.
      @child_account.settings = merged_settings(settings)
    end

    # `details` is deliberately NOT merged: the frontend clears an AAC profile
    # field by DELETING its key, so a merge would make "Not set" a no-op.
    details = params[:details]
    if details
      @child_account.details = details
    end
    apply_top_level_aac_profile_params!(@child_account)

    if params[:layout]
      @child_account.layout = params[:layout]
    end

    # The sandbox board cap is meaningless once promoted, and the wholesale
    # settings replace used to drop it as a side effect. Match
    # ChildAccount#promote_to_active! and clear it deliberately.
    if was_sandbox && requested_status != ChildAccount::SANDBOX
      @child_account.settings ||= {}
      @child_account.settings.delete("demo_board_limit")
    end

    if @child_account.save
      render json: @child_account.api_view(current_user), status: :ok
    else
      message = @child_account.errors.full_messages.join(", ")
      render json: account_error_payload(message, record: @child_account), status: :unprocessable_content
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

    # Only ids not already on the dashboard cost anything — re-assigning an
    # attached board is a no-op, so counting it against a cap would refuse a
    # request that was going to change nothing.
    attached_ids = @child_account.child_boards.pluck(:board_id)
    new_ids = board_ids - attached_ids

    total_boards = @child_account.child_boards.count + new_ids.size
    if @child_account.sandbox?
      demo_limit = (@child_account.settings["demo_board_limit"] || ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT).to_i
      if total_boards > demo_limit
        render json: { error: "Demo board limit exceeded. You can have up to #{demo_limit} boards." }, status: :unprocessable_content
        return
      end
    end

    # Assignment attaches a board rather than copying it, so it spends no board
    # slot at all. This per-communicator cap is what bounds how big a single
    # dashboard can get.
    if @child_account.at_assigned_board_limit?(new_ids.size)
      render json: { error: "assigned_board_limit",
                     message: "This communicator can hold up to #{ChildAccount.max_assigned_boards} boards.",
                     limit: ChildAccount.max_assigned_boards,
                     count: @child_account.child_boards.count },
             status: :unprocessable_content
      return
    end

    source = Boards::AssignableSource.new(@child_account, actor: current_user)
    refused = []

    board_ids.each do |board_id|
      resolved = source.resolve(board_id)
      if resolved.nil?
        refused << board_id
        next
      end

      board, = resolved
      # ATTACH, don't copy. One board row on N dashboards: editing it reaches
      # every communicator using it, which is the whole point — there is no
      # per-communicator copy left to fall out of sync. `find_or_create_by!`
      # rides the unique index on (board_id, child_account_id), so a repeat
      # assign is idempotent instead of minting a second copy.
      @child_account.child_boards.find_or_create_by!(board: board) do |cb|
        cb.created_by_id = current_user.id
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.error "[assign_boards] board #{board_id}: #{e.message}"
      refused << board_id
    end

    if refused.any? && refused.size == board_ids.size
      # Generic on purpose: naming which id was refused would say whether a
      # board the caller cannot see exists.
      render json: { error: "boards_not_assignable",
                     message: "Those boards can't be added to this communicator." },
             status: :unprocessable_content
      return
    end

    payload = @child_account.api_view(current_user)
    payload = payload.merge(boards_not_assignable: refused) if refused.any?
    render json: payload, status: :ok
  end

  # DELETE /child_accounts/1
  # DELETE /child_accounts/1.json
  def destroy
    unless @child_account.owner_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    # A lent-out communicator has a live claim link a family may be about to
    # use — deleting it would orphan that link mid-hand-off. Mirror the archive
    # guard: end the loan first. (reclaim! frees the slot and clears the token.)
    if @child_account.loaner?
      render json: account_error_payload("End the loan first via end_loan."), status: :unprocessable_content
      return
    end

    @child_account.destroy!
  end

  private

  # Merge an incoming settings blob over what's stored, so a caller that only
  # knows about its own slice can't wipe the rest. Shallow on purpose: a
  # nested hash the caller does send (`voice`) is replaced whole, which is how
  # clearing a voice to `{"name" => ""}` stays possible.
  #
  # Clearing a top-level key still works by sending an explicit blank/nil —
  # what no longer works is clearing by omission, which nothing does.
  def merged_settings(incoming)
    (@child_account.settings || {}).merge(normalized_settings(incoming))
  end

  # A settings blob straight off the wire: plain string-keyed hash (never an
  # ActionController::Parameters handed to a jsonb column), booleans typed.
  # The AAC profile fields (age_band, aac_level, vocab_type, glp_stage) live in
  # the `details` jsonb and have always been settable through the `details`
  # param. Accepting them at the TOP LEVEL as well matches how the rest of this
  # controller reads its params (`name`, `username`, `status`, `layout` are all
  # top-level), so a caller sending `{ age_band: "15-18" }` gets an update
  # rather than a silent no-op.
  #
  # Applied AFTER `details`, so a request carrying both has the explicit
  # top-level field win. `key?` rather than `present?`: sending a blank is how a
  # caller clears one, and normalize_aac_profile_fields already drops blanks.
  def apply_top_level_aac_profile_params!(record)
    ChildAccount::AAC_PROFILE_FIELDS.each_key do |field|
      next unless params.key?(field)

      record.public_send("#{field}=", params[field])
    end
  end

  def normalized_settings(incoming)
    incoming = incoming.to_unsafe_h if incoming.respond_to?(:to_unsafe_h)
    cast_boolean_settings(incoming.to_h.deep_stringify_keys)
  end

  # This blob is unwhitelisted by design (each tab sends its own slice and new
  # keys arrive without a deploy), but the flags the app BRANCHES on have to be
  # real booleans: a string "false" is truthy in Ruby, so an untyped value
  # would read as "on" everywhere the setting is checked.
  def cast_boolean_settings(settings)
    bool = ActiveModel::Type::Boolean.new
    DisplaySettingsDefaults::REQUIRED_SETTINGS.each do |key|
      # nil is left alone: clearing a key by sending nil is how a caller asks
      # for the model default back (ensure_settings refills it).
      next if settings[key].nil?

      settings[key] = bool.cast(settings[key]) || false
    end
    settings
  end

  # Use callbacks to share common setup or constraints between actions.
  # `with_archived` so unarchive (and admin maintenance) can target a
  # soft-archived record — the default scope hides them otherwise.
  def set_child_account
    @parent_account = current_user
    @child_account = ChildAccount.with_archived.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def child_account_params
    # :user_id is intentionally NOT permitted — ownership is assigned server-side
    # (@child_account.owner = current_user in #create), so a client can't set or
    # reassign ownership via mass-assignment (#27).
    params.require(:child_account).permit(:username, :name)
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

    render json: account_error_payload("not_authorized").merge(
      message: "Only the owner can edit this communicator.",
    ), status: :forbidden
  end

  # Curation gate for board assignment: the account owner, a team
  # supervisor, or a system admin may add boards to the communicator's
  # dashboard (`can_add_boards_to_account?`). This matches the `can_edit`
  # flag in the serializer and the ChildBoard curate path — owner-only here
  # would contradict the UI. Plan is intentionally NOT checked: a
  # free/cancelled supervisor still curates per decision 3.
  def authorize_communicator_curate!
    return if current_user.can_add_boards_to_account?([@child_account.id])

    render json: {
      error: "not_authorized",
      message: "Only the account owner or a team supervisor can add boards to this dashboard.",
    }, status: :forbidden
  end

  # Lending / hand-off is a paid, plan-gated feature. The frontend already
  # hides the LoanerControls for plans without it, but the gate must also hold
  # on the server: without it a Basic user (or any direct API caller) could
  # promote a sandbox to a loaner, or lend a self-created active — the
  # active→loaner path in `lend` skips the slot check, so nothing else
  # would stop them. System admins bypass for support.
  #
  # The plan question is `User#can_lend?`, NOT `pro?`: the Clinician plan
  # advertises loaner slots and its entire workflow is lend → family claims →
  # slot recycles, but it is deliberately not Pro (its smaller slot cap is the
  # product). The error code stays `pro_required` — it is the contract the
  # frontend already renders, and free/basic still see exactly what they saw —
  # the refusal copy stays Pro-worded because Pro is genuinely where the
  # remaining refused plans (free / basic / vendor) upgrade to.
  # Slot math is unaffected: a clinician lends within their own 2 slots.
  #
  # Called *after* the per-action ownership check so a non-owner still
  # gets the generic Unauthorized response and we don't leak the gate.
  # Returns true when allowed; otherwise renders 403 and returns false so
  # the caller can `return unless require_pro_for_lending!`.
  def require_pro_for_lending!
    return true if current_user.admin? || current_user.can_lend?

    render json: account_error_payload("pro_required").merge(
      message: "Lending a communicator to a family is a Pro feature.",
      upgrade_url: "/account/billing/upgrade",
    ), status: :forbidden
    false
  end

  # The machine-readable half of a slot/quota refusal (#820). The prose in
  # `error` names no limit and offers no path — a clinician at 2/2 saw
  # "Maximum number of communicator accounts reached." mid-form with nothing to
  # act on — so every refusal also carries a stable `error_code` plus the
  # numbers it was decided against. The prose string is left byte-identical;
  # the frontend renders it verbatim today and owns the replacement copy.
  # `usage_for` costs a count query, so this is the REFUSAL path only.
  def slot_limit_details(user, status, error_code)
    return {} if error_code.blank?

    usage = Permissions::CommunicatorLimits.usage_for(user: user, status: status)
    { error_code: error_code, limit: usage[:limit], count: usage[:count] }
  end

  # Mutation endpoints (lend, end_loan, etc.) return the current account
  # view in error responses so a frontend that does
  # `setState(response)` doesn't lose the status / is_demo fields and
  # flip into the wrong UI state. The error message is included as a
  # sibling field so callers that DO check can still surface it.
  #
  # It RELOADS the record to serialize it, which discards
  # the unsaved attributes and the errors that came with them — so `field_errors`
  # has to be read off the record BEFORE that happens. Callers pass the record
  # explicitly (`record:`) rather than relying on `@child_account` for the same
  # reason: the flat `error` string is often a hand-written sentence with no
  # validation behind it at all, and those must not grow a `field_errors` key.
  #
  # Additive: `error` and `errors` keep their exact existing shape (one flat
  # string under both keys), so a client that reads either is untouched.
  def account_error_payload(error, record: nil)
    fields = field_errors_for(record)
    view = @child_account ? @child_account.reload.api_view(current_user) : {}
    view = view.merge(error: error.to_s, errors: error.to_s)
    fields.present? ? view.merge(field_errors: fields) : view
  end

  # `{ "username" => ["Username has already been taken"] }` — full sentences
  # keyed by field, so the frontend can attach the message to the input that
  # caused it instead of printing one flattened string. `to_hash(true)` is the
  # full-message form; the plain `to_hash` would give bare fragments
  # ("has already been taken") that read badly on their own.
  def field_errors_for(record)
    return {} if record.nil? || record.errors.empty?

    record.errors.to_hash(true).transform_keys(&:to_s)
  end

  # The shape a username is actually stored in. `parameterize` matches
  # ChildAccount#set_username_if_missing, which is what the create path uses
  # when the client sends a name and no username — so the availability answer
  # and the create both key on the same string.
  def normalized_username(value)
    value.to_s.strip.downcase.parameterize
  end

  # Up to 3 alternatives that are CONFIRMED free, resolved in one query rather
  # than an `exists?` per candidate. Deliberately no auto-suffixing on the
  # create path: the parent should see and choose the name, not discover later
  # that the app silently renamed their child's account to "leo2".
  def username_suggestions(base)
    initial = current_user.name.to_s.strip.split(/\s+/).last.to_s[0, 1].downcase.gsub(/[^a-z0-9]/, "")
    year = Time.zone.today.year

    # Readable options first — a parent has to be willing to say this name out
    # loud. The random tail is last: it is the one candidate that is very
    # unlikely to collide, so it keeps the list non-empty when a popular name
    # has already taken every tidy variant.
    candidates = [
      "#{base}2",
      ("#{base}-#{initial}" if initial.present?),
      "#{base}-#{year}",
      "#{base}3",
      "#{base}-1",
      "#{base}#{rand(10..99)}",
      "#{base}#{SecureRandom.hex(2)}",
    ].compact.map { |c| normalized_username(c) }.uniq - [base]

    taken = ChildAccount.where(username: candidates).pluck(:username).to_set
    candidates.reject { |c| taken.include?(c) }.first(3)
  end
end
