class API::UsersController < API::ApplicationController
  before_action :set_user, only: %i[ show update_settings destroy update ]

  # GET /users or /users.json
  def index
    if current_user&.admin?
      @users = User.all.order(created_at: :desc)
    else
      @users = [current_user]
    end
    render json: @users.map(&:api_view)
  end

  # GET /users/1 or /users/1.json
  def show
    unless current_user&.admin? || current_user == @user
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
    @user.name = user_params[:name]

    if @user.save
      render json: @user, status: :ok
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  def set_password
    # @user = User.find(params[:id])
    @user = current_user
    Rails.logger.info("Setting password for user: #{@user.inspect}")
    Rails.logger.info("Params received: #{params.inspect}")
    password = params[:password]
    password_confirmation = params[:password_confirmation]
    if password != password_confirmation
      render json: { error: "Password confirmation does not match" }, status: :unprocessable_entity
      return
    end
    @user.password = password
    @user.password_confirmation = password_confirmation
    @user.force_password_reset = false
    if @user.save
      render json: { success: true }, status: :ok
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
    params.each do |key, value|
      @user.settings[key] = value
    end

    respond_to do |format|
      if @user.save
        format.json { render json: @user, status: :ok }
      else
        format.json { render json: @user.errors, status: :unprocessable_entity }
      end
    end
  end

  def send_delete_account_email
    @user = current_user
    Rails.logger.info "Generating delete account token for user #{@user.id}"
    expire_time = 2.hours.from_now
    @user.delete_account_token = SecureRandom.hex(16)
    @user.delete_account_token_expires_at = expire_time
    @user.save!
    UserMailer.delete_account_email(@user).deliver_later
    render json: { success: true }, status: :ok
  end

  def delete_account
    @user = current_user
    # TODO - Apple doesn't allow for confirmation emails to be sent before deletion
    # so we skip token verification for Apple users

    # if @user.nil? || @user.email != params[:email] || @user.delete_account_token != params[:token]
    #   render json: { error: "Invalid or expired token" }, status: :unprocessable_entity
    #   return
    # end

    # if @user.nil? || @user.delete_account_token_expires_at.nil? || @user.delete_account_token_expires_at < Time.current
    #   render json: { error: "Invalid or expired token" }, status: :unprocessable_entity
    #   return
    # end
    if @user.admin?
      render json: { error: "Admin accounts cannot be deleted via this method" }, status: forbidden
      return
    end
    if @user.soft_delete_account!(reason: "user_requested", actor_id: @user.id)
      render json: { success: true }, status: :ok
    else
      render json: { error: "Failed to delete account" }, status: :unprocessable_entity
    end
  end

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
