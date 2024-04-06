module API
  class ApplicationController < ApplicationController
    prepend_before_action :authenticate_token!

    private

    def authenticate_token!
      user = user_from_token
      if user
        sign_in user, store: false
      else
        puts "Unauthorized"
        # direct to login page
        render json: { error: "Unauthorized" }, status: :unauthorized
        # head :unauthorized
      end
    end

    def user_from_token
      User.find_by(authentication_token: token) if token.present?
    end

    def current_user
      @current_user ||= user_from_token
    end

    def token
      request.headers.fetch("Authorization", "").split(" ").last
    end
  end
end
