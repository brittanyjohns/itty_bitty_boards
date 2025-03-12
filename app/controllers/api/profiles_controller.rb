class API::ProfilesController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[public]

  def show
    @profile = Profile.find(params[:id])
    render json: @profile
  end

  def public
    @profile = Profile.find_by(slug: params[:slug])
    render json: @profile.public_view
  end

  def update
    @profile = Profile.find(params[:id])
    if @profile.update(profile_params)
      render json: @profile
    else
      render json: @profile.errors, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, :slug, settings: {})
  end
end
