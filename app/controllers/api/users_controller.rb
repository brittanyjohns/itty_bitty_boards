class API::UsersController < API::ApplicationController
  before_action :set_user, only: %i[ show update_settings destroy ]

  # GET /users or /users.json
  def index
    @users = User.all
  end

  # GET /users/1 or /users/1.json
  def show
  end

  # PATCH/PUT /users/1 or /users/1.json
  def update_settings
    puts "PARAMS: #{params}"
    @user = User.find(params[:id])
    user_setting_params = params[:user]
    user_settings = @user.settings || {}
    puts "User settings params: #{user_params} user_settings: #{user_settings}"
    voice_settings = user_params[:voice] || {}
    puts "Voice settings: #{voice_settings}"
    @user.settings = user_settings.merge(voice: voice_settings)
    puts "User settings after merge: #{@user.inspect}"

    respond_to do |format|
      if @user.save
        format.json { render json: @user, status: :ok }
      else
        format.json { render json: @user.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /users/1 or /users/1.json
  def destroy
    @user.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_user
    @user = User.find(params[:id])
  end

  def restrict
    redirect_to root_path unless current_user&.admin?
  end

  # Only allow a list of trusted parameters through.
  def user_params
    params.require(:user).permit(:name, :email, :base_words, voice: [:name, :speed, :pitch, :rate, :volume, :language])
  end
end