# Identify the current user from your existing API token/JWT
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_account

    def connect
      token = request.params["token"] # e.g., your JWT from ?token=...

      self.current_account = ChildAccount.find_by(authentication_token: token) if token.present?
      reject_unauthorized_connection unless self.current_account
    rescue StandardError
      reject_unauthorized_connection
    end
  end
end
