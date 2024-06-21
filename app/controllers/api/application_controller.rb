module API
  class ApplicationController < ApplicationController
    prepend_before_action :authenticate_token!

    def current_order
      return nil if current_user.nil?
      if user_session["order_id"].nil?
        order = current_user.orders.in_progress.last || current_user.orders.create!
      else
        begin
          order = current_user.orders.in_progress.find(user_session["order_id"])
        rescue ActiveRecord::RecordNotFound => e
          order = current_user.orders.create!
        rescue => e
          puts "\n\n****Error: #{e.inspect}\n\n"
        end
      end
      user_session["order_id"] = order.id unless order.nil?
      order
    end

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
      User.with_artifacts.find_by(authentication_token: token) if token.present?
    end

    def current_user
      @current_user ||= user_from_token
    end

    def token
      request.headers.fetch("Authorization", "").split(" ").last
    end
  end
end
