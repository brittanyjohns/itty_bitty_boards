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
    @user = current_user

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

  def update_email
    unless current_user.valid_password?(params[:current_password])
      return render json: { error: "Current password is incorrect" }, status: :unauthorized
    end
    new_email = params[:email].to_s.strip.downcase

    if new_email.blank?
      return render json: { error: "Email can't be blank" }, status: :unprocessable_entity
    end

    if new_email == current_user.email
      return render json: {
                      message: "That is already your current email.",
                      email: current_user.email,
                    }, status: :ok
    end

    if User.where.not(id: current_user.id).exists?(email: new_email) ||
       User.where.not(id: current_user.id).exists?(unconfirmed_email: new_email)
      return render json: { error: "Email is already taken" }, status: :unprocessable_entity
    end

    if current_user.update(unconfirmed_email: new_email)
      token = SecureRandom.hex(16)
      if current_user.update(confirmation_token: token, confirmation_sent_at: Time.current)
        UserMailer.confirm_update_email(current_user).deliver_now
        render json: {
                 message: "Confirmation email sent to #{new_email}. Your current email will stay active until you confirm.",
                 current_email: current_user.email,
                 pending_email: current_user.unconfirmed_email,
               }, status: :ok
      else
        render json: { error: "Failed to update email" }, status: :unprocessable_entity
      end
    else
      render json: { errors: current_user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def confirm_email_change
    token = params[:confirmation_token]
    user = User.find_by(confirmation_token: token)

    if user.nil? || user.confirmation_token != token
      return render json: { error: "Invalid or expired token" }, status: :unprocessable_entity
    end
    user.email = user.unconfirmed_email
    user.unconfirmed_email = nil
    user.confirmation_token = nil
    user.confirmed_at = Time.current
    if user.save
      render json: { message: "Email change confirmed", email: user.email }, status: :ok
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def resend_email_confirmation
    pending_email = current_user.unconfirmed_email

    if pending_email.blank?
      return render json: { error: "No pending email change." }, status: :unprocessable_entity
    end

    # current_user.send_confirmation_instructions
    if current_user.confirmation_token.nil? || current_user.confirmation_sent_at < 1.hour.ago
      token = SecureRandom.hex(16)
      current_user.update(confirmation_token: token, confirmation_sent_at: Time.current)
    end
    UserMailer.confirm_update_email(current_user).deliver_now

    render json: {
      message: "Confirmation email resent to #{pending_email}.",
    }, status: :ok
  end

  def cancel_email_change
    if current_user.unconfirmed_email.present?
      current_user.update_column(:unconfirmed_email, nil)
      current_user.update_column(:confirmation_token, nil)
      current_user.update_column(:confirmation_sent_at, nil)

      render json: { message: "Pending email change canceled." }, status: :ok
    else
      render json: { error: "No pending email change." }, status: :unprocessable_entity
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

  # Required for Apple Store account deletion - sends email with token to confirm deletion

  def send_delete_account_email
    @user = current_user
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
      render json: { error: "Admin accounts cannot be deleted via this method" }, status: :forbidden
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
