module API
    module V1
      class AuthsController < ApplicationController
        skip_before_action :authenticate_token!, only: [:create, :sign_up]

        def sign_up
          if params['user']['first_name']
            name = params['user']['first_name'] + " " + params['user']['last_name']
          elsif params['user']['name']
            name = params['user']['name']
          else
            name = ""
          end
          user = User.new(email: params['user']['email'], password: params['user']['password'], password_confirmation: params['user']['password_confirmation'], name: name)
          if user.save
            render json: {token: user.authentication_token}
          else
            render json: {error: user.errors.full_messages.join(", ")}, status: :unprocessable_entity
          end
        end
  
        def create
          puts "params: #{params.inspect}"
          if (user = User.valid_credentials?(params[:email], params[:password]))
            sign_in user
            render json: {token: user.authentication_token}
          else
            render json: {error: error_message}, status: :unauthorized
          end
        end
  
        def destroy
        #   destroy_notification_token
          sign_out(current_user)
          render json: {}
        end
  
        private
  
        def error_message
          I18n.t("devise.failure.invalid", authentication_keys: :email)
        end

        def sign_up_params
          params.require(:user).permit(:email, :password, :password_confirmation, first_name: "", last_name: "")
        end
  
        # def destroy_notification_token
        #   current_user.notification_tokens.where(token: params[:token]).destroy_all
        # end
      end
    end
  end