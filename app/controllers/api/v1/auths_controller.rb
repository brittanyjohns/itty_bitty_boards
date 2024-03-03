module API
    module V1
      class AuthsController < ApplicationController
        skip_before_action :authenticate_token!, only: [:create, :sign_up, :current]

        def sign_up
          puts "SIGN UP params: #{params.inspect}"
          if params['auth'] && params['auth']['first_name'] && params['auth']['last_name']
            name = params['auth']['first_name'] + " " + params['auth']['last_name']
          elsif params['auth'] && params['auth']['name']
            name = params['auth']['name']
          else
            name = ""
          end
          user = User.new(email: params['auth']['email'], password: params['auth']['password'], password_confirmation: params['auth']['password_confirmation'], name: name)
          if user.save
            render json: {token: user.authentication_token, user: user}
          else
            render json: {error: user.errors.full_messages.join(", ")}, status: :unprocessable_entity
          end
        end
  
        def create
          puts "SIGN IN params: #{params.inspect}"
          if (user = User.valid_credentials?(params[:email], params[:password]))
            sign_in user
            render json: {token: user.authentication_token, user: user}
          else
            render json: {error: error_message}, status: :unauthorized
          end
        end

        def current
          if current_user
            render json: {user: current_user}
          else
            current_user = user_from_token
            if current_user
              render json: {user: current_user}
            else
              render json: {error: "Unauthorized - No user signed in"}, status: :unauthorized
            end
          end
        end
  
        def destroy
          sign_out(current_user)
          @current_user = nil
          render json: {message: "Signed out successfully", status: :ok}
        end
  
        private
  
        def error_message
          I18n.t("devise.failure.invalid", authentication_keys: :email)
        end

        def sign_up_params
          params.require(:user).permit(:email, :password, :password_confirmation, first_name: "", last_name: "")
        end
      end
    end
  end