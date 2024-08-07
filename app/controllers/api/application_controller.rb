module API
  class ApplicationController < ApplicationController
    prepend_before_action :authenticate_token!
    skip_before_action :authenticate_token!, only: %i[authenticate_child_token!]

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

    def authenticate_child_token!
      child = child_from_token
      if child
        puts "Child authenticated"
        sign_in child, store: false
      else
        puts "Unauthorized"
        # direct to login page
        render json: { error: "Unauthorized child account" }, status: :unauthorized
        # head :unauthorized
      end
    end

    def authenticate_signed_in!
      if current_user
        puts "User signed in"
      elsif current_child
        puts "Child signed in"
      else
        puts "Unauthorized"
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    private

    def user_from_token
      User.find_by(authentication_token: token) if token.present?
    end

    def child_from_token
      ChildAccount.find_by(authentication_token: token) if token.present?
    end

    def current_child
      @current_child ||= child_from_token
    end

    def current_user
      @current_user ||= user_from_token
    end

    def token
      request.headers.fetch("Authorization", "").split(" ").last
    end
  end
end
