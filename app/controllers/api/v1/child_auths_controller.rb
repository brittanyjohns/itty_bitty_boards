module API
  module V1
    class ChildAuthsController < ApplicationController
      skip_before_action :authenticate_token!, only: [:create, :current, :destroy]

      def create
        puts "Params: #{params}"
        parent_id = params[:user_id]
        username = params[:username]
        password = params[:password]
        puts "Parent ID: #{parent_id}, Username: #{username}, Password: #{password}"

        if (child = ChildAccount.valid_credentials?(parent_id, username, password))
          auth_token = child.authentication_token
          puts "Auth Token: #{auth_token}"
          sign_in child
          render json: { token: child.authentication_token, child: child }
        else
          render json: { error: error_message }, status: :unauthorized
        end
      end

      def current
        if current_child
          render json: { child: current_child.api_view }
        else
          current_child = child_from_token
          if current_child
            render json: { child: current_child }
          else
            render json: { error: "Unauthorized - No child signed in" }, status: :unauthorized
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
  end
end
