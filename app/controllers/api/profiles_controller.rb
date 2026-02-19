class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public check_placeholder generate claim_placeholder next_placeholder]

  def index
    @profile = current_user&.profile
    puts "Current user profile: #{@profile.inspect}" if @profile
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
    Rails.logger.debug("[Profiles#public] public_page=#{@profile.public_page?}")
    render json: (@profile.public_page? ? @profile.public_page_view : @profile.safety_view)
  end

  def create
    if current_user.nil?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    Rails.logger.debug("[Profiles#create] raw params keys=#{params.keys}")
    Rails.logger.debug("[Profiles#create] profile params=#{profile_params.to_h}")

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
      @user.settings["board_limit"] = 1
      @user.settings["demo_communicator_limit"] = 1
      @user.settings["paid_communicator_limit"] = 0
      @user.settings["ai_monthly_limit"] = 10
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
    params.require(:profile).permit(:username, :bio, :intro, :avatar, settings: {})
  end
end
