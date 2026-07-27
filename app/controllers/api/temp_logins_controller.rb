# app/controllers/api/temp_logins_controller.rb
class API::TempLoginsController < API::ApplicationController
  # No `skip_before_action :authenticate_user!` here: no ancestor registers that
  # callback, so skipping it raises "callback has not been defined" under eager
  # loading. `authenticate_token!` IS registered (API::ApplicationController), so
  # that skip stays — it's what makes this endpoint reachable without a token.
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

    # The temp-login link was delivered to their inbox, so reaching here proves
    # they control that address. Idempotent — a repeat login grants nothing new.
    # Verification must never break login: this is a login path, so a failure
    # here is logged and swallowed rather than raised.
    begin
      user.mark_email_verified!
    rescue => e
      Rails.logger.error "temp_logins#show: mark_email_verified! failed for #{user.email}: #{e.class}: #{e.message} — continuing, sign-in must not be blocked"
    end

    render json: {
      success: true,
      force_password_reset: user.force_password_reset,
      token: user.authentication_token,
      user: user.api_view,
    }
  end
end
