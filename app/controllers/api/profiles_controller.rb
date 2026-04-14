class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public check_placeholder generate claim_placeholder next_placeholder]

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
    @profile = Profile.find_by(slug: params[:slug])

    if @profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end

    if @profile.placeholder? && @profile.claimed_at.nil?
      render json: @profile.placeholder_view
      return
    end

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

  def create
    if current_user.nil?
      render json: { error: "Unauthorized" }, status: :unauthorized
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
      render json: profile.api_view(current_user), status: :created
    else
      Rails.logger.debug("[Profiles#create] errors=#{profile.errors.full_messages}")
      render json: {
        error: "Profile creation failed",
        details: profile.errors.full_messages,
      }, status: :unprocessable_entity
    end
  end

  def update
    profile = Profile.find(params[:id])
    slug = params.dig(:profile, :slug)
    if slug.blank?
      slug = profile.username.parameterize if profile.username.present?
    end
    slug ||= SecureRandom.hex(4)
    profile.slug = slug

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
      }, status: :unprocessable_entity
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
      render json: { error: "This username has been taken. Please try again." }, status: :unprocessable_entity
      return
    end
    if params[:user_email].blank?
      render json: { error: "Email is required" }, status: :unprocessable_entity
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
        render json: { error: "Failed to invite user" }, status: :unprocessable_entity
        return
      end
    end

    @profile = Profile.generate_with_username(username, user) if user
    if @profile
      render json: @profile.placeholder_view
    else
      render json: { error: "Failed to generate placeholder" }, status: :unprocessable_entity
    end
  end

  # def update
  #   @profile = Profile.find(params[:id])
  #   if @profile.update(profile_params)
  #     render json: @profile.api_view(current_user)
  #   else
  #     render json: @profile.errors, status: :unprocessable_entity
  #   end
  # end

  def check_placeholder
    profile = Profile.find_by(slug: params[:slug])
    profile = Profile.find_by(claim_token: params[:slug]) if profile.nil?
    if profile.nil?
      render json: { error: "Profile not found" }, status: :not_found
      return
    end

    render json: profile.placeholder_view
  end

  def claim_placeholder
    if params[:claim_token].blank?
      render json: { error: "Claim token is required" }, status: :unprocessable_entity
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
      render json: { error: "Email is required" }, status: :unprocessable_entity
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
    unless @user.plan_type == "pro" || @user.plan_type == "basic"
      @user.plan_type = "myspeak"
      @user.plan_status = "pending"
      @user.setup_myspeak_limits
    else
      Rails.logger.debug "User already has plan_type: #{@user.plan_type}, skipping plan assignment"
    end

    @user.settings[:myspeak_slug] = slug

    @user.save!
    begin
      @profile = @profile.claim!(slug, @user)
    rescue StandardError => e
      Rails.logger.error "Failed to claim profile: #{e.message}"
      render json: { errors: e.message }, status: :unprocessable_entity and return
    end
    @profile.reload
    @slug = @profile.slug
    @user.send_welcome_with_claim_link_email(@slug)

    render json: @profile
  end

  private

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
    ]
  end

  def profile_public_page_settings(profile)
    settings = profile.settings || {}
    public_page = settings["public_page"] || settings[:public_page] || {}
    public_page.is_a?(Hash) ? public_page : {}
  end

  def public_page_board_ids(profile)
    if profile.profileable_type == "ChildAccount"
      board_ids = profile.communication_boards.pluck(:id)
      return board_ids
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
