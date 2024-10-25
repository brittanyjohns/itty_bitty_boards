class API::V1::ChildAuthsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: [:create, :current, :destroy]

  def create
    parent_id = params[:user_id]
    username = params[:username]
    password = params[:password]
    puts "Parent ID: #{parent_id} Username: #{username} Password: #{password}"

    if (child = ChildAccount.valid_credentials?(username, password))
      puts "Child found: #{child.print_credentials}"
      auth_token = child.authentication_token
      user_context = child.user

      unless child.can_sign_in?(user_context)
        if user_context&.admin?
          return render json: { token: auth_token, child: child }
        end
        return render json: { error: "Account not active. Please upgrade to a pro account to continue.", token: "" }, status: :unauthorized
      end

      return render json: { token: child.authentication_token, child: child }
    else
      return render json: { error: error_message }, status: :unauthorized
    end
  end

  def current
    if current_child
      return render json: { child: current_child.api_view }
    else
      current_child = child_from_token
      if current_child
        return render json: { child: current_child }
      else
        return render json: { error: "Unauthorized - No child signed in" }, status: :unauthorized
      end
    end
  end

  def destroy
    sign_out(current_child)
    @current_child = nil
    render json: { message: "Signed out successfully", status: :ok }
  end

  private

  def error_message
    I18n.t("devise.failure.invalid", authentication_keys: :username)
  end

  def sign_up_params
    params.require(:child).permit(:username, :password, :password_confirmation, first_name: "", last_name: "")
  end
end
