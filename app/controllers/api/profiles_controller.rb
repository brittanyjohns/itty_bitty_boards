class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public check_placeholder generate claim_placeholder next_placeholder]
  before_action :set_available_placeholders, only: %i[check_placeholder claim_placeholder next_placeholder]

  def index
    @profile = current_user&.profile
    puts "Current user profile: #{@profile.inspect}" if @profile
    render json: @profile.api_view(current_user)
  end

  def show
    @profile = Profile.find(params[:id])
    render json: @profile.api_view(current_user)
  end

  def placeholders
    @profiles = Profile.where(placeholder: true)
    render json: @profiles.map(&:placeholder_view)
  end

  def next_placeholder
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
    render json: @profile.public_view
  end

  def create
    @profile = Profile.new(profile_params)
    @profile.user = current_user
    @profile.slug = params[:slug] if params[:slug].present?
    if @profile.save
      render json: @profile.api_view(current_user), status: :created
    else
      render json: @profile.errors, status: :unprocessable_entity
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

  def update
    @profile = Profile.find(params[:id])
    if @profile.update(profile_params)
      render json: @profile.api_view(current_user)
    else
      render json: @profile.errors, status: :unprocessable_entity
    end
  end

  def check_placeholder
    profile = @available_placeholders.find_by(slug: params[:slug])
    profile = @available_placeholders.find_by(claim_token: params[:slug]) if profile.nil?
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
    @profile = @available_placeholders.find_by(claim_token: params[:claim_token]) if params[:claim_token].present?
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
      @user.settings["communicator_limit"] = 0
    else
      Rails.logger.debug "User already has plan_type: #{@user.plan_type}, skipping plan assignment"
    end

    @user.settings[:myspeak_slug] = slug

    @user.save!
    @profile = @profile.claim!(slug, @user)
    @profile.reload
    @slug = @profile.slug
    @user.send_welcome_with_claim_link_email(@slug)

    render json: @profile
  end

  private

  def set_available_placeholders
    @available_placeholders = Profile.available_placeholders
  end

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, :sku, :slug, settings: {})
  end
end
