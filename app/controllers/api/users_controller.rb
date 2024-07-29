class API::UsersController < API::ApplicationController
  before_action :set_user, only: %i[ show update_settings destroy update ]

  # GET /users or /users.json
  def index
    @users = User.all
  end

  # GET /users/1 or /users/1.json
  def show
  end

  def update
    puts "Update plan params: #{params}"
    @user = User.find(params[:id])
    @user.plan_type = user_params[:plan_type]
    puts "User plan type: #{@user.plan_type}"
    if @user.save
      render json: @user, status: :ok
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /users/1 or /users/1.json
  def update_settings
    @user = User.find(params[:id])
    user_settings = @user.settings || {}
    puts "User settings: #{user_settings}"
    puts "Params: #{params}"
    puts "wait params: #{params[:wait_to_speak]}"
    voice_settings = params[:voice] || {}
    puts "Voice settings: #{voice_settings}"
    @user.settings = user_settings.merge(voice: voice_settings)
    @user.base_words = params[:base_words]
    @user.settings["wait_to_speak"] = params[:wait_to_speak] || false
    @user.settings["disable_audit_logging"] = params[:disable_audit_logging] || false
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
    params.require(:user).permit(:name, :email, :base_words, :plan_type,
                                 voice: [:name, :speed, :pitch, :rate, :volume, :language])
  end
end
