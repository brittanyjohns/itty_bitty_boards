# app/services/temp_login_service.rb
class TempLoginService
  EXPIRY = User::TEMP_LOGIN_TOKEN_EXPIRY_HOURS.hours

  def self.issue_for!(user)
    token = SecureRandom.urlsafe_base64(32)

    user.update!(
      temp_login_token: token,
      temp_login_expires_at: EXPIRY.from_now,
      force_password_reset: true,
    )

    token
  end
end
