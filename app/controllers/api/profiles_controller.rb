class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public safety_view care_view check_placeholder generate claim_placeholder next_placeholder check_slug]

  def index
    @profile = current_user&.profile
    render json: @profile.api_view(current_user)
  end

  def show
    @profile = Profile.find(params[:id])

    render json: (@profile.public_page? ? @profile.public_page_view : @profile.safety_view)
  end

  def placeholders
    @profiles = Profile.where(placeholder: true)
    render json: @profiles.map(&:placeholder_view)
  end

  def next_placeholder
    set_placeholders
    @profile = @available_placeholders.order(:created_at).first
    if @profile
      render json: @profile.placeholder_view
    else
      render json: { error: "No available placeholder profiles" }, status: :not_found
    end
  end

  def public
    @profile, resolved_by = Profile.resolve_slug(params[:slug])

    # Legacy-slug fallback — a safety profile migrated to a random slug keeps
    # its old name-based slug in `legacy_slug`. Printed cards, bookmarks, and
    # search results that still point at the old URL get a permanent redirect
    # to the current slug so they keep working.
    #
    # A `permanent_slug` match is NOT redirected: it's the QR target on a
    # device tag, so it serves the page directly and never depends on what the
    # public slug happens to be today.
    if resolved_by == :legacy
      redirect_to "/api/profiles/public/#{@profile.slug}", status: :moved_permanently
      return
    end

    if @profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end

    if @profile.placeholder? && @profile.claimed_at.nil?
      render json: @profile.placeholder_view
      return
    end

    # NOTE: page-open no longer logs a view or alerts the parent. The MySpeak
    # page is the everyday "social" surface and carries no sensitive data
    # (see Profile#safety_view). The view log + throttled parent alert now fire
    # only when someone deliberately opens the emergency info — see #safety_view
    # below (issue #384).

    response.headers["Cache-Control"] = "no-cache, private, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"

    last_modified = profile_public_last_modified(@profile)
    etag = profile_public_etag(@profile)

    if stale?(etag: etag, last_modified: last_modified, public: false)
      payload = @profile.public_page? ? @profile.public_page_view : @profile.safety_view
      render json: payload
    end
  end

  # Gated safety-details endpoint (issue #384). The open MySpeak page withholds
  # medical info + emergency contacts; this returns them — but only as the
  # deliberate "Emergency Info" action. This is also the single place that
  # records the access and (throttled) alerts the parent, so page-open is
  # zero-friction and notification-free while the actual emergency reveal is
  # both logged and visible to the family.
  def safety_view
    # Resolves the canonical, printed (permanent), and legacy addresses alike —
    # a QR that opens the page must not 404 on the reveal behind it.
    profile, = Profile.resolve_slug(params[:slug])

    if profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end

    unless profile.safety?
      render json: { error: "Not a safety profile" }, status: :not_found
      return
    end

    # An unclaimed placeholder has no owner or real safety data — reveal nothing
    # and don't bother recording.
    if profile.placeholder? && profile.claimed_at.nil?
      render json: { id: profile.id, settings: {} }
      return
    end

    log_safety_profile_view(profile)

    render json: profile.safety_details_view
  end

  # Gated care-details endpoint. Same shape as #safety_view — the open page
  # withholds settings["care"] and this is the deliberate reveal — but a
  # DIFFERENT notification contract: the access is logged for the abuse-pattern
  # history and the parent is NOT alerted. Care sections are day-to-day support
  # info (how someone communicates, eats, gets home), so a substitute teacher
  # reading them is routine; routing them through the emergency alert would
  # train parents to ignore it.
  def care_view
    # Resolves the canonical, printed (permanent), and legacy addresses alike —
    # a QR that opens the page must not 404 on the reveal behind it.
    profile, = Profile.resolve_slug(params[:slug])

    if profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end

    unless profile.safety?
      render json: { error: "Not a safety profile" }, status: :not_found
      return
    end

    if profile.placeholder? && profile.claimed_at.nil?
      render json: { id: profile.id, settings: {} }
      return
    end

    log_care_profile_view(profile)

    render json: profile.care_details_view
  end

  def create
    if current_user.nil?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    # A user has exactly ONE Public page (User `has_one :profile`), on every
    # plan. A duplicate is a state conflict, not a plan gate — 409, never 403.
    # A second row would be unreachable anyway: `user.profile` returns an
    # arbitrary one of them. The per-communicator MySpeak page is a different
    # product with a different quota (the communicator slot) — see #761.
    if (existing = current_user.profile)
      Analytics::CommunicatorEvents.public_page_create_blocked(
        user: current_user,
        reason: "public_page_exists",
      )
      render json: {
        error: "public_page_exists",
        message: "You already have a public page.",
        profile_id: existing.id,
        slug: existing.slug,
      }, status: :conflict
      return
    end

    profile = Profile.new(profile_params)
    profile.profileable = current_user

    # Prefer nested profile slug (since your FormData uses profile[slug])
    slug = params.dig(:profile, :slug)
    if slug.blank?
      slug = profile.username.parameterize if profile.username.present?
    end
    slug ||= "user-#{SecureRandom.hex(4)}"
    profile.slug = slug
    username = profile.username
    if username.blank?
      username = slug
    end
    profile.username = username

    if profile.save
      profile.enqueue_audio_job_if_needed
      profile.generate_attachments! if profile.safety?
      Analytics::CommunicatorEvents.public_page_created(user: current_user, profile: profile)
      render json: profile.api_view(current_user), status: :created
    else
      Rails.logger.debug("[Profiles#create] errors=#{profile.errors.full_messages}")
      render json: {
        error: "Profile creation failed",
        details: profile.errors.full_messages,
      }, status: :unprocessable_content
    end
  end

  def update
    profile = Profile.find(params[:id])

    # Safety / Emergency profile on a communicator is owner-only.
    # See marketing/.claude-notes/handoff-workflow.md (Permissions matrix).
    if profile.profileable_type == "ChildAccount" &&
       !profile.profileable.editable_by?(current_user)
      render json: { error: "not_owner" }, status: :forbidden
      return
    end

    # Slug update gating — the public URL slug is editable at most once per
    # 7 days for everyone except admins. The frontend uses the error code +
    # next_edit_at to render a "Locked until <date>" hint.
    requested_slug = params.dig(:profile, :slug).to_s.strip.downcase.presence
    if requested_slug && requested_slug != profile.slug
      unless profile.slug_editable? || current_user&.admin?
        # A random safety link is locked forever, not until a date: it exists
        # so the page can't be found by guessing a child's name, and letting
        # the owner rename it back to that name would undo the protection.
        # Answered as its own code because `slug_locked`'s copy is built around
        # a `next_edit_at` this case doesn't have.
        if profile.slug_permanent?
          render json: {
            error: "slug_permanent",
            message: "This link is randomly generated so the page can't be found by " \
                     "guessing a name, so it can't be renamed. If you need to stop " \
                     "an old link working, get a new one instead.",
          }, status: :unprocessable_content
          return
        end

        next_at = profile.slug_editable_at
        render json: {
          error: "slug_locked",
          next_edit_at: next_at,
          message: "You can change your link again on #{next_at&.to_date&.iso8601}.",
        }, status: :unprocessable_content
        return
      end

      # slug_unavailable_reason counts the profile's own slug as a collision;
      # recompute "taken" while excluding this profile's id so a no-op-equivalent
      # submission isn't rejected.
      reason = Profile.slug_unavailable_reason(requested_slug)
      if reason == :taken && Profile.slug_available?(requested_slug, except_id: profile.id)
        reason = nil
      end

      if reason
        render json: slug_error_for(reason), status: :unprocessable_content
        return
      end

      profile.slug = requested_slug
    end

    public_about = params.dig(:profile, :public_about_html)
    public_intro = params.dig(:profile, :public_intro_html)
    public_bio = params.dig(:profile, :public_bio_html)

    profile.public_about = public_about unless public_about.blank?
    profile.public_intro = public_intro unless public_intro.blank?
    profile.public_bio = public_bio unless public_bio.blank?

    if profile.update(profile_params)
      profile.enqueue_audio_job_if_needed
      profile.generate_attachments! if profile.safety?
      render json: profile.api_view(current_user)
    else
      Rails.logger.debug("[Profiles#update] errors=#{profile.errors.full_messages}")
      render json: {
        error: "Profile update failed",
        details: profile.errors.full_messages,
      }, status: :unprocessable_content
    end
  end

  # "Get a new link" — mints a fresh random slug and drops the old one.
  #
  # This is the answer to a LEAKED link, which a permanently-frozen slug had no
  # answer for: an unguessable URL is still a bearer token, and whoever holds it
  # keeps access until the address changes. Not gated on `slug_editable?` — that
  # governs choosing a name, and refusing to revoke until a 7-day window opens
  # would be exactly backwards.
  #
  # The printed device tag is unaffected (its QR resolves through
  # `permanent_slug`), but a tag rendered before that column existed still
  # points at the old address, so the card is regenerated once here. After that
  # first rotation a profile's paper is immune to every future one.
  def rotate_slug
    profile = Profile.find(params[:id])

    unless can_manage_profile?(profile)
      render json: { error: "not_owner" }, status: :forbidden
      return
    end

    previous_slug = profile.slug
    profile.rotate_slug!
    RegenerateSafetyCardsJob.perform_later(profile.id) if profile.safety?

    render json: profile.api_view(current_user).merge(previous_slug: previous_slug)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn "[Profiles#rotate_slug] #{e.record.errors.full_messages.join(", ")}"
    render json: { error: "slug_rotation_failed" }, status: :unprocessable_content
  end

  # Live availability check used by the slug picker UI. Returns the same
  # reason vocabulary the create/update endpoints use.
  def check_slug
    candidate = params[:slug].to_s.strip.downcase
    if candidate.blank?
      render json: { available: false, reason: "format" }
      return
    end

    reason = Profile.slug_unavailable_reason(candidate)
    if reason
      render json: { available: false, reason: reason.to_s, slug: candidate }
    else
      render json: { available: true, reason: "ok", slug: candidate }
    end
  end

  def generate
    username = params[:username]
    if username.blank?
      username = SecureRandom.hex(4)
      params[:username] = username
    end
    @profile = Profile.find_by(username: username)
    slug = username.parameterize
    @profile = Profile.find_by(slug: slug) if @profile.nil?
    if @profile
      render json: { error: "This username has been taken. Please try again." }, status: :unprocessable_content
      return
    end
    if params[:user_email].blank?
      render json: { error: "Email is required" }, status: :unprocessable_content
      return
    end
    if params[:user_email].present?
      existing_user = User.find_by(email: params[:user_email])
      new_user = User.create_from_email(params[:user_email], nil, nil, slug) unless existing_user
      user = existing_user || new_user
      if user
        params[:user_id] = user.id
        params[:user_email] = user.email
      else
        render json: { error: "Failed to invite user" }, status: :unprocessable_content
        return
      end
    end

    @profile = Profile.generate_with_username(username, user) if user
    if @profile
      render json: @profile.placeholder_view
    else
      render json: { error: "Failed to generate placeholder" }, status: :unprocessable_content
    end
  end

  # def update
  #   @profile = Profile.find(params[:id])
  #   if @profile.update(profile_params)
  #     render json: @profile.api_view(current_user)
  #   else
  #     render json: @profile.errors, status: :unprocessable_content
  #   end
  # end

  def check_placeholder
    # This is the printed-card path by definition — someone is typing what's on
    # a card — so it resolves the permanent address too.
    profile, = Profile.resolve_slug(params[:slug])
    profile = Profile.find_by(claim_token: params[:slug]) if profile.nil?
    if profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end

    render json: profile.placeholder_view
  end

  def claim_placeholder
    if params[:claim_token].blank?
      render json: { error: "Claim token is required" }, status: :unprocessable_content
      return
    end
    @profile = Profile.find_by(claim_token: params[:claim_token]) if params[:claim_token].present?
    if @profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end
    email = params[:email]
    slug = params[:slug]
    if email.blank?
      render json: { error: "Email is required" }, status: :unprocessable_content
      return
    end
    if slug.blank?
      slug = SecureRandom.hex(4)
      params[:slug] = slug
    end
    @user = User.find_by(email: email)
    found_user = @user
    @user = User.invite!(email: email, skip_invitation: true) unless @user
    @user.settings ||= {}
    # MySpeak is a free feature: newly invited claimers default to the free
    # plan, which includes a demo-communicator slot. Existing users keep
    # whatever plan they already have.
    @user.settings[:myspeak_slug] = slug

    @user.save!
    begin
      @profile = @profile.claim!(slug, @user)
    rescue StandardError => e
      Rails.logger.error "Failed to claim profile: #{e.message}"
      render json: { errors: e.message }, status: :unprocessable_content and return
    end
    @profile.reload
    @slug = @profile.slug
    @user.send_welcome_with_claim_link_email(@slug)

    render json: @profile
  end

  private

  # Same ownership rule #update enforces, in one place so a second write path
  # can't drift from it: a communicator's page is owner-only, a user's own page
  # is theirs, and an admin may act on either.
  def can_manage_profile?(profile)
    return true if current_user&.admin?

    if profile.profileable_type == "ChildAccount"
      profile.profileable.editable_by?(current_user)
    else
      profile.profileable_id == current_user&.id && profile.profileable_type == "User"
    end
  end

  # Maps a Profile.slug_unavailable_reason symbol to the JSON shape the
  # client renders next to the slug field. Keep error codes in sync with
  # the strings the React `SlugField` checks.
  def slug_error_for(reason)
    case reason
    when :format
      {
        error: "slug_invalid",
        message: "Links must be 3–40 characters: lowercase letters, numbers, and hyphens.",
      }
    when :reserved
      {
        error: "slug_reserved",
        message: "That link is reserved. Please pick another.",
      }
    when :taken
      {
        error: "slug_taken",
        message: "That link is already in use.",
      }
    else
      { error: "slug_invalid", message: "That link can't be used." }
    end
  end

  # Enqueue async view-logging + parent alert for a safety profile. All heavy
  # lifting (geolocation, throttle, email) happens in RecordProfileViewJob; here
  # we only capture the request IP + user agent and hand off. Rescues broadly so
  # a Redis outage can't 500 the public page.
  def log_safety_profile_view(profile)
    return unless profile.safety?

    RecordProfileViewJob.perform_async(profile.id, request.remote_ip, request.user_agent)
  rescue => e
    Rails.logger.warn("[Profiles#public] failed to enqueue view log: #{e.class}: #{e.message}")
  end

  # Same hand-off as log_safety_profile_view, but tagged "care" so the job logs
  # the view and stops short of the parent alert.
  def log_care_profile_view(profile)
    return unless profile.safety?

    RecordProfileViewJob.perform_async(profile.id, request.remote_ip, request.user_agent, "care")
  rescue => e
    Rails.logger.warn("[Profiles#care_view] failed to enqueue view log: #{e.class}: #{e.message}")
  end

  def set_placeholders
    @available_placeholders = Profile.available_placeholders
  end

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, :allow_discovery, settings: {})
  end

  def profile_public_last_modified(profile)
    timestamps = [profile.updated_at]

    board_ids = public_page_board_ids(profile)
    if board_ids.any?
      board_ts = Board.where(id: board_ids).maximum(:updated_at)
      timestamps << board_ts if board_ts
    end

    timestamps.compact.max || Time.zone.at(0)
  end

  def profile_public_etag(profile)
    public_page = profile_public_page_settings(profile)
    board_sections = Array(public_page["board_sections"])
    featured_board_ids = Array(public_page["featured_board_ids"])
    board_ids = public_page_board_ids(profile)

    boards_scope = board_ids.any? ? Board.where(id: board_ids) : Board.none

    normalized_sections = board_sections.map do |section|
      {
        id: section["id"],
        title: section["title"],
        layout: section["layout"],
        subtext: section["subtext"],
        board_ids: Array(section["board_ids"]),
      }
    end

    [
      "profile-public-v3",
      profile.id,
      profile.cache_key_with_version,
      profile.public_page?,
      profile.allow_discovery?,
      Digest::MD5.hexdigest(public_page.to_json),
      Digest::MD5.hexdigest(normalized_sections.to_json),
      featured_board_ids.join("-"),
      boards_scope.count,
      boards_scope.maximum(:id),
      boards_scope.maximum(:updated_at)&.utc&.to_fs(:nsec),
      # The admin board library rides along in the body as
      # `general_public_boards`, so a change to it has to be able to bust a
      # cached page — without this a client can be served a stale 304.
      Board.public_board_cards_cache_key,
    ]
  end

  def profile_public_page_settings(profile)
    settings = profile.settings || {}
    public_page = settings["public_page"] || settings[:public_page] || {}
    public_page.is_a?(Hash) ? public_page : {}
  end

  def public_page_board_ids(profile)
    if profile.profileable_type == "ChildAccount"
      # communication_boards is favorite_boards, which returns ChildBoard join
      # rows — pluck the Board they point at, not the join row's own id. These
      # ids are handed to Board.where(id:) by the freshness helpers below, so
      # plucking :id keyed the ETag off arbitrary unrelated boards.
      return profile.communication_boards.pluck(:board_id).compact.uniq
    end
    public_page = profile_public_page_settings(profile)

    section_board_ids =
      Array(public_page["board_sections"]).flat_map do |section|
        Array(section["board_ids"])
      end

    featured_board_ids = Array(public_page["featured_board_ids"])

    (section_board_ids + featured_board_ids).compact.uniq
  end
end
