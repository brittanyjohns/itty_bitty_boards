class API::V1::ChildAuthsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: [:create, :current, :destroy]

  def create
    parent_id = params[:user_id]
    username = params[:username]
    password = params[:password]

    if (child = ChildAccount.valid_credentials?(username, password))
      auth_token = child.authentication_token
      user_context = child.user

      unless child.can_sign_in?(user_context)
        if user_context&.admin?
          child.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip, sign_in_count: child.sign_in_count + 1)
          return render json: { token: auth_token, account: child }
        end
        # Temporarily disable this check
        # return render json: { error: "Account not active. Please upgrade to a pro account to continue.", token: "" }, status: :unauthorized
      end
      if auth_token.nil?
        child.reset_authentication_token!
      end
      auth_token = child.authentication_token
      child.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip, sign_in_count: child.sign_in_count + 1)
      return render json: { token: auth_token, account: child.api_view }
    else
      return render json: { error: error_message }, status: :unauthorized
    end
  end

  def current
    @current_account = current_account
    if @current_account
      # @current_account.reload
      @view = @current_account.api_view
      render json: { account: @view }
    else
      puts "No current account"
      @current_account = user_from_token
      if @current_account
        render json: { account: @current_account.api_view }
      else
        render json: { error: "Unauthorized - No user signed in" }, status: :unauthorized
      end
    end
  end

  def destroy
    sign_out(current_account)
    @current_account = nil
    render json: { message: "Signed out successfully", status: :ok }
  end

  private

  def current_account
    @current_account ||= child_from_token
  end

  def error_message
    I18n.t("devise.failure.invalid", authentication_keys: :username)
  end

  def sign_up_params
    params.require(:child).permit(:username, :password, :password_confirmation, first_name: "", last_name: "")
  end
end
