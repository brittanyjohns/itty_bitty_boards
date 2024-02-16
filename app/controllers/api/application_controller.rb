module API
  class ApplicationController < ApplicationController
    prepend_before_action :authenticate_token!

    private

    def authenticate_token!
      if (user = user_from_token)
        sign_in user, store: false
      else
        head :unauthorized
      end
    end

    def user_from_token
      User.find_by(authentication_token: token) if token.present?
    end

    def token
      request.headers.fetch("Authorization", "").split(" ").last
    end
  end
end