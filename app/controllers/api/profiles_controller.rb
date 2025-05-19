class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public check_placeholder]

  def show
    @profile = Profile.find(params[:id])
    render json: @profile
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

  def update
    @profile = Profile.find(params[:id])
    if @profile.update(profile_params)
      render json: @profile.api_view(current_user)
    else
      render json: @profile.errors, status: :unprocessable_entity
    end
  end

  def check_placeholder
    profile = Profile.find_by!(slug: params[:slug], placeholder: true)
    render json: profile
  end

  private

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, :slug, settings: {})
  end
end
