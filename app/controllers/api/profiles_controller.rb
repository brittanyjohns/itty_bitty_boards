class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public check_placeholder generate]

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
    render json: @profiles.map(&:public_view)
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
      user = User.find_by(email: params[:user_email])
      existing_user = user

      user = User.create_from_email(params[:user_email], nil, nil, slug)
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
    profile = Profile.find_by!(slug: params[:slug])

    render json: profile
  end

  private

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, :slug, settings: {})
  end
end
