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
    puts "Settings: #{params[:profile][:settings]}"
    puts "Profile Params: #{profile_params.inspect}"
    puts "Profile: #{@profile.inspect}"
    if @profile.update(profile_params)
      render json: @profile.api_view(current_user)
    else
      render json: @profile.errors, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, :slug, settings: {})
  end
end
