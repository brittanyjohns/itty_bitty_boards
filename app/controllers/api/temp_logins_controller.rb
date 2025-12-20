# app/controllers/api/temp_logins_controller.rb
class API::TempLoginsController < API::ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :authenticate_token!

  def show
    Rails.logger.info("Temp login attempt with token: #{params[:token]}")
    user = User.find_by(temp_login_token: params[:token])
    Rails.logger.info("Temp login user found: #{user.inspect}")
    temp_login_expires_at = user&.temp_login_expires_at
    Rails.logger.info("Temp login token expires at: #{user&.temp_login_expires_at}")
    Rails.logger.info("Current time: #{Time.current}")
    Rails.logger.info("Token valid: #{!user.nil? && user.temp_login_expires_at >= Time.current}")
    Rails.logger.info("User force password reset: #{user&.force_password_reset}")

    if user.nil? || user.temp_login_expires_at < Time.current
      render json: { success: false, error: "expired" }, status: :unauthorized
      return
    end

    sign_in(user) # Devise session cookie

    # one-time use
    user.update!(
      temp_login_token: nil,
      temp_login_expires_at: nil,
    )

    render json: {
      success: true,
      force_password_reset: user.force_password_reset,
      token: user.authentication_token,
      user: user.api_view,
    }
  end
end
