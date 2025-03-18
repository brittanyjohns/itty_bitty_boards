class API::Admin::UsersController < API::Admin::ApplicationController
  before_action :set_user, only: %i[ show destroy update ]

  # GET /users or /users.json
  def index
    sort_order = params[:sort_order] || "desc"
    sort_field = params[:sort_field] || "created_at"
    @users = User.includes(:child_accounts, :word_events, :boards)
    @users = @users.order(sort_field => sort_order.to_sym)

    render json: @users
  end

  # GET /users/1 or /users/1.json
  def show
    if @user.locked?
      @user.settings["locked"] = true
    end
    @word_events = @user.word_events.order(created_at: :desc).limit(25)
    @user_api_view = @user.admin_api_view.merge(word_events: @word_events.map(&:api_view))
    render json: @user_api_view
  end

  def update
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
    if @user.save
      render json: @user, status: :ok
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  # def admin_update_settings
  #   unless current_user&.admin?
  #     render json: { error: "Unauthorized" }, status: :unauthorized
  #     return
  #   end
  #   @user = User.find(params[:id])
  #   user_settings = @user.settings || {}

  #   voice_settings = params[:voice] || {}
  #   @user.settings = user_settings.merge(voice: voice_settings)
  #   @user.base_words = params[:base_words]
  #   @user.settings["wait_to_speak"] = params[:wait_to_speak] || false
  #   @user.settings["disable_audit_logging"] = params[:disable_audit_logging] || false
  #   @user.settings["enable_image_display"] = params[:enable_image_display] || false
  #   @user.settings["enable_text_display"] = params[:enable_text_display] || false

  #   # ADMIN ONLY
  #   @user.plan_type = params[:plan_type]
  #   @user.locked = params[:locked] || false
  #   @user.settings["locked"] = params[:locked] || false

  #   respond_to do |format|
  #     if @user.save
  #       format.json { render json: @user, status: :ok }
  #     else
  #       format.json { render json: @user.errors, status: :unprocessable_entity }
  #     end
  #   end
  # end

  # DELETE /users/1 or /users/1.json
  def destroy
    unless current_user&.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    @user.destroy!

    render json: { success: true }
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
