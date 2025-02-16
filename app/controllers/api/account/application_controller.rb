module API
  module Account
    class ApplicationController < ActionController::Base
      prepend_before_action :authenticate_child_token!

      def authenticate_child_token!
        @child ||= child_from_token
        if @child
          # sign_in @child
        else
          puts "Unauthorized"
          # direct to login page
          render json: { error: "Unauthorized child account" }, status: :unauthorized
          # head :unauthorized
        end
      end

      def child_from_token
        @child_from_token ||= ChildAccount.find_by(authentication_token: token) if token.present?
      end

      def current_account
        @current_account ||= child_from_token
      end

      private

      def token
        request.headers.fetch("Authorization", "").split(" ").last
      end
    end
  end
end
