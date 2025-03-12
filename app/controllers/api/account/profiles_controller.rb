class API::Account::ProfilesController < API::Account::ApplicationController
  def me
    render json: current_account.profile.api_view
  end

  def update_me
    @profile = current_account.profile

    if @profile.update(profile_params)
      render json: @profile.api_view
    else
      render json: @profile.errors, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:profile).permit(:username, :bio, :intro, :avatar, settings: {})
  end
end
