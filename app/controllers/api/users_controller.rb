class API::UsersController < API::ApplicationController
  before_action :set_user, only: %i[ show update_settings destroy update ]

  # GET /users or /users.json
  def index
    if current_user&.admin?
      @users = User.all.order(created_at: :desc)
    else
      @users = [current_user]
    end
    render json: @users
  end

  # GET /users/1 or /users/1.json
  def show
    unless current_user&.admin? || current_user == @user
      puts ">>>> Unauthorized"
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    if @user.locked?
      @user.settings["locked"] = true
    end
    render json: @user.api_view
  end

  def update
    @user = User.find(params[:id])
    @user.plan_type = user_params[:plan_type]
    @user.name = user_params[:name]

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

    voice_settings = params[:voice] || {}
    @user.settings = user_settings.merge(voice: voice_settings)
    @user.base_words = params[:base_words]
    @user.settings["wait_to_speak"] = params[:wait_to_speak] || false
    @user.settings["disable_audit_logging"] = params[:disable_audit_logging] || false
    @user.settings["enable_image_display"] = params[:enable_image_display] || false
    @user.settings["enable_text_display"] = params[:enable_text_display] || false

    respond_to do |format|
      if @user.save
        format.json { render json: @user, status: :ok }
      else
        format.json { render json: @user.errors, status: :unprocessable_entity }
      end
    end
  end

  def admin_update_settings
    unless current_user&.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    @user = User.find(params[:id])
    user_settings = @user.settings || {}

    voice_settings = params[:voice] || {}
    @user.settings = user_settings.merge(voice: voice_settings)
    @user.base_words = params[:base_words]
    @user.settings["wait_to_speak"] = params[:wait_to_speak] || false
    @user.settings["disable_audit_logging"] = params[:disable_audit_logging] || false
    @user.settings["enable_image_display"] = params[:enable_image_display] || false
    @user.settings["enable_text_display"] = params[:enable_text_display] || false

    # ADMIN ONLY
    @user.plan_type = params[:plan_type]
    @user.locked = params[:locked] || false
    @user.settings["locked"] = params[:locked] || false

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
