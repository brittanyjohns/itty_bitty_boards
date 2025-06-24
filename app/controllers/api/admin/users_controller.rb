class API::Admin::UsersController < API::Admin::ApplicationController
  before_action :set_user, only: %i[ show destroy update ]

  # GET /users or /users.json
  def index
    sort_order = params[:sort_order] || "desc"
    sort_field = params[:sort_field] || "created_at"
    @users = User.includes(:child_accounts, :word_events, :boards)
    if sort_field == "board_count"
      @users = @users.sort_by { |u| u.boards.count }
      if sort_order == "desc"
        @users = @users.reverse
      end
    else
      @users = @users.order(sort_field => sort_order.to_sym)
    end

    render json: @users.map(&:admin_index_view)
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
    plan_type = params[:plan_type] || @user.plan_type || "free"
    @user.plan_type = plan_type
    @user.locked = params[:locked] || false
    @user.settings["locked"] = params[:locked] || false
    @user.settings["board_limit"] = params[:board_limit] || 0
    @user.settings["communicator_limit"] = params[:communicator_limit] || 0
    if @user.save
      render json: @user, status: :ok
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  def export
    unless current_admin&.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    @users = User.all

    send_data @users.to_csv,
              filename: "users-#{Time.now.strftime("%Y-%m-%d")}.csv",
              type: "text/csv"
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
    unless current_admin
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    if @user.admin?
      render json: { error: "Cannot delete an admin user" }, status: :unprocessable_entity
      return
    end
    begin
      @user.destroy!
    rescue ActiveRecord::RecordNotDestroyed => e
      render json: { error: e.message }, status: :unprocessable_entity
      return
    end
    puts "User #{@user.id} deleted by #{current_admin.display_name}"

    render json: { success: true }
  end

  def destroy_users
    puts "CURRENT USER: #{current_admin.display_name} - admin? #{current_admin&.admin?}"
    unless current_admin&.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    unless params[:user_ids].present?
      render json: { error: "No user_ids provided" }, status: :unprocessable_entity
      return
    end
    result = User.where(id: params[:user_ids]).map(&:destroy!)
    response = result.all? ? { status: :ok } : { status: :unprocessable_entity }
    render json: response
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
