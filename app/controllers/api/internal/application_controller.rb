module API
  module Internal
    class ApplicationController < ::ApplicationController
      skip_before_action :verify_authenticity_token, raise: false
      before_action :authenticate_internal_api_key!

      private

      def authenticate_internal_api_key!
        expected = ENV["INTERNAL_API_KEY"].to_s
        provided = request.headers["Authorization"].to_s.split(" ", 2).last.to_s

        if expected.blank? || provided.blank? ||
           !ActiveSupport::SecurityUtils.secure_compare(expected, provided)
          render json: { error: "Unauthorized" }, status: :unauthorized
        end
      end

      def current_user
        @current_user ||= User.find(User::DEFAULT_ADMIN_ID)
      end
    end
  end
end
