module API
  module Admin
    class ApplicationController < ApplicationController
      prepend_before_action :authenticate_admin!

      def authenticate_admin!
        @admin ||= admin_from_token
        unless @admin
          Rails.logger.warn "Unauthorized admin access attempt"
          render json: { error: "Unauthorized" }, status: :unauthorized
        end
      end

      def admin_from_token
        @admin_from_token ||= User.find_by(authentication_token: token, role: "admin") if token.present?
      end

      def current_admin
        @current_admin ||= admin_from_token
      end

      private

      def token
        request.headers.fetch("Authorization", "").split(" ").last
      end
    end
  end
end
