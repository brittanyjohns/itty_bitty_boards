module API
  module V1
    class ChildAuthsController < ApplicationController
      skip_before_action :authenticate_token!, only: [:create, :sign_up, :current, :destroy, :forgot_password, :reset_password]

      # def sign_up
      # if params["auth"] && params["auth"]["first_name"] && params["auth"]["last_name"]
      #   name = params["auth"]["first_name"] + " " + params["auth"]["last_name"]
      # elsif params["auth"] && params["auth"]["name"]
      #   name = params["auth"]["name"]
      # else
      #   name = ""
      # end
      # child = ChildAccount.new(username: params["auth"]["username"], password: params["auth"]["password"], password_confirmation: params["auth"]["password_confirmation"], name: name)
      # if child.save
      #   render json: { token: child.authentication_token, child: child }
      # else
      #   puts "\n***\nChildAccount Errors: #{child.errors.full_messages.join(", ")}"
      #   render json: { error: child.errors.full_messages.join(", ") }, status: :unprocessable_entity
      # end
      # end

      def create
        if (child = ChildAccount.valid_credentials?(params[:username], params[:password]))
          sign_in child
          render json: { token: child.authentication_token, child: child }
        else
          render json: { error: error_message }, status: :unauthorized
        end
      end

      # def forgot_password
      #   puts "\n***\nForgot Password: #{params[:username]}"
      #   child = ChildAccount.find_by(username: params[:username])
      #   if child
      #     reset_token = child.send_reset_password_instructions
      #     child.update(reset_password_token: reset_token)
      #     puts "\n***\nReset child: #{child.username} with token: #{reset_token}"

      #     render json: { message: "Password reset instructions sent to #{child.username}" }
      #   else
      #     render json: { error: "No child found with username #{params[:username]}" }, status: :not_found
      #   end
      # end

      def reset_password
        child = ChildAccount.find_by(reset_password_token: params[:reset_password_token])
        if child
          child.reset_password(params[:password], params[:password_confirmation])
          render json: { message: "Password reset successfully" }
        else
          render json: { error: "Invalid reset password token" }, status: :not_found
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
