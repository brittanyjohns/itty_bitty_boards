module API
  class ApplicationController < ApplicationController
    prepend_before_action :authenticate_token!
    skip_before_action :authenticate_token!, only: %i[authenticate_child_token!]
    include ActiveStorage::SetCurrent

    # application_controller.rb
    rescue_from ActionController::InvalidAuthenticityToken do |e|
      Rails.logger.warn "CSRF fail UA=#{request.user_agent} IP=#{request.remote_ip} Origin=#{request.headers["Origin"]} Referrer=#{request.referer} Cookies?=#{request.cookies.present?}"
      raise
    end

    def authenticate_token!
      @user ||= user_from_token
      if @user
        # sign_in @user
        true
      else
        render json: { error: "Unauthorized" }, status: :unauthorized
        # head :unauthorized
      end
    end

    def authenticate_child_token!
      @child ||= child_from_token
      if @child
        # sign_in @child
      else
        render json: { error: "Unauthorized child account" }, status: :unauthorized
      end
    end

    def authenticate_signed_in!
      if current_user
      elsif current_account
      else
        puts "Unauthorized"
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def check_daily_limit(feature_key)
      Rails.logger.debug "Checking daily limit for feature: #{feature_key}, User ID: #{current_user.id}"
      limiter = DailyFeatureLimiter.new(
        user_id: current_user.id,
        feature_key: feature_key,
        limit: current_user.daily_limit_for(feature_key),
        tz: current_user.timezone || "America/New_York",
      )
      allowed, meta = limiter.increment_and_check!
      Rails.logger.debug "Daily limit check result for User ID: #{current_user.id}, " \
                         "Feature: #{feature_key} - Allowed: #{allowed}, Meta: #{meta}"
      error_message = "Daily limit reached for #{feature_key}. Please try again later."
      unless allowed
        render json: { error: "limit_reached", message: error_message, **meta }, status: 429
        return false
      end
      true
    end

    private

    def user_from_token
      @user_from_token ||= User.find_by(authentication_token: token) if token.present?
    end

    def child_from_token
      @child_from_token ||= ChildAccount.find_by(authentication_token: token) if token.present?
    end

    def current_account
      @current_account ||= child_from_token
    end

    def current_user
      @current_user ||= user_from_token
      @current_user
    end

    def token
      request.headers.fetch("Authorization", "").split(" ").last
    end
  end
end
