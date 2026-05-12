module API
  class ApplicationController < ApplicationController
    prepend_before_action :authenticate_token!
    skip_before_action :authenticate_token!, only: %i[authenticate_child_token! preset_colors]
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
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def check_monthly_limit(feature_key: nil, feature_name: nil, credit_feature_key: nil)
      unless current_user && feature_key
        Rails.logger.warn "Monthly limit check missing user or feature_key. user_id=#{current_user&.id} feature_key=#{feature_key}"
        return true
      end
      limiter = MonthlyFeatureLimiter.new(
        user_id: current_user.id,
        feature_key: feature_key,
        limit: current_user.monthly_limit_for(feature_key),
        tz: current_user.timezone || "America/New_York",
      )
      allowed, meta = limiter.increment_and_check!

      # Shadow-mode credit accounting: try to spend weighted credits but never block
      # on the result. Failures are logged for Phase 1 telemetry; the Redis limiter
      # remains the source of truth until enforcement is switched on.
      shadow_credit_spend(credit_feature_key || feature_key, redis_allowed: allowed)

      error_message = "Monthly limit reached for #{feature_name || feature_key.titleize}. Please upgrade your plan or wait until next month."
      unless allowed
        render json: { error: "limit_reached", message: error_message, **meta }, status: 429
        return false
      end
      true
    end

    def shadow_credit_spend(feature_key, redis_allowed:)
      return unless current_user
      credit_allowed = CreditService.shadow_spend(
        current_user,
        feature_key: feature_key,
        metadata: { shadow: true, redis_allowed: redis_allowed, path: request.path },
      )
      if credit_allowed != redis_allowed
        Rails.logger.info "[CreditService][shadow][divergence] user=#{current_user.id} feature=#{feature_key} redis_allowed=#{redis_allowed} credit_allowed=#{credit_allowed}"
      end
    rescue => e
      Rails.logger.error "[CreditService][shadow] unexpected error: #{e.class} #{e.message}"
    end

    def preset_colors
      @colors = ColorHelper::PRESET_DATA
      render json: { preset_colors: @colors }
    end

    def voice_options
      render json: {
               voices: VoiceService.get_voice_options,
               labels: VoiceService.get_voice_labels, # optional legacy
             }
    end

    def normalize_plan_key(plan_key)
      case plan_key
      when "myspeak", "myspeak_yearly"
        "myspeak"
      when "basic", "basic_yearly"
        "basic"
      when "pro", "pro_yearly"
        "pro"
      else
        plan_key
      end
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
