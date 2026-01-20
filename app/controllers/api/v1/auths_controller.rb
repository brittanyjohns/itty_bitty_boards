module API
  module V1
    class AuthsController < ApplicationController
      skip_before_action :authenticate_token!, only: [:create, :sign_up, :current, :destroy, :forgot_password, :reset_password, :reset_password_invite]

      def sign_up
        if params["auth"] && params["auth"]["first_name"] && params["auth"]["last_name"]
          name = params["auth"]["first_name"] + " " + params["auth"]["last_name"]
        elsif params["auth"] && params["auth"]["name"]
          name = params["auth"]["name"]
        else
          name = ""
        end

        user = User.new(email: params["auth"]["email"], password: params["auth"]["password"], password_confirmation: params["auth"]["password_confirmation"], name: name)
        if user.save
          Rails.logger.info "New user signed up: #{user.email} at #{Time.now}"
          # result = Stripe::Customer.create({ email: user.email })
          result = User.create_stripe_customer(user.email)
          Rails.logger.info "Stripe customer created for new user #{user.email}: #{result}"
          Rails.logger.info "Plan type param: #{params["plan_type"]}" if params["plan_type"]
          user.stripe_customer_id = result
          if params["plan_type"] && params["plan_type"] == "partner_pro"
            user.plan_type = "partner_pro"
            user.plan_status = "active"
            user.role = "partner"
            User.handle_new_partner_pro_subscription(user, params["plan_type"])
          end

          # Send welcome email
          # UserMailer.welcome_email(user).deliver_now
          # user.send_welcome_email
          sign_in user
          user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
          if user.role == "partner"
            user.send_partner_welcome_email
          end
          MailchimpEventJob.perform_async(user.id, "sign_up")
          render json: { token: user.authentication_token, user: user.api_view }
        else
          render json: { error: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      def create
        if (user = User.valid_credentials?(params[:email], params[:password]))
          if user.locked?
            render json: { error: "Your account is locked. Please contact support." }, status: :unauthorized
            return
          end
          if user.plan_status == "pending cancelation"
            if user.subscription_expired?
              user.plan_status = "active"
              user.plan_expires_at = nil
              user.plan_type = "free"
              user.settings["paid_communicator_limit"] = 0
              user.settings["demo_communicator_limit"] = 0
              user.settings["board_limit"] = 1
              user.save!
            end
          end
          Rails.logger.info "User signed in: #{user.email} at #{Time.now}"
          sign_in user
          user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
          MailchimpEventJob.perform_async(user.id, "sign_in")
          render json: { token: user.authentication_token, user: user.api_view }
        else
          render json: { error: error_message }, status: :unauthorized
        end
      end

      def forgot_password
        user = User.find_by(email: params[:email])
        if user
          reset_token = user.send_reset_password_instructions
          user.update(reset_password_token: reset_token)

          render json: { message: "Password reset instructions sent to #{user.email}" }
        else
          render json: { error: "No user found with email #{params[:email]}" }, status: :not_found
        end
      end

      def reset_password
        user = User.find_by(reset_password_token: params[:reset_password_token])
        if user
          user.reset_password(params[:password], params[:password_confirmation])
          render json: { message: "Password reset successfully" }
        else
          render json: { error: "Invalid reset password token" }, status: :not_found
        end
      end

      def reset_password_invite
        unless params[:invitation_token]
          render json: { error: "No invitation token provided" }, status: :not_found
          return
        end
        user = User.accept_invitation!(invitation_token: params[:invitation_token], password: params[:password], password_confirmation: params[:password_confirmation])
        name = params[:name] unless params[:name].blank?
        role = params[:role] unless params[:role].blank?
        if user && user.errors.empty?
          user.update(name: name) unless name.blank?
          team_user = TeamUser.find_by(user_id: user.id)
          if team_user
            team_user.update(role: role) unless role.blank?
          end
        end
        if user
          sign_in user
          user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
          render json: { message: "Password set. Please sign in.", user: user, token: user.authentication_token }
        else
          render json: { error: "Invalid reset password token" }, status: :not_found
        end
      end

      def current
        @current_user = current_user
        if @current_user
          @view = @current_user.api_view
          render json: { user: @view }
        else
          @current_user = user_from_token
          if @current_user
            render json: { user: @current_user.api_view }
          else
            render json: { error: "Unauthorized - No user signed in" }, status: :unauthorized
          end
        end
      end

      def destroy
        sign_out(current_user)
        @current_user = nil
        render json: { message: "Signed out successfully", status: :ok }
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
