module API
  module V1
    class AuthsController < ApplicationController
      skip_before_action :authenticate_token!, only: [:create, :sign_up, :email_signup, :google, :current, :destroy, :forgot_password, :reset_password, :reset_password_invite]

      def sign_up
        name = params["name"] || (params["user"] && params["user"]["name"]) || ""
        platform = params["platform"] || ""
        email = params["email"] || (params["auth"] && params["auth"]["email"])
        password = params["password"] || (params["auth"] && params["auth"]["password"])
        password_confirmation = params["password_confirmation"] || (params["auth"] && params["auth"]["password_confirmation"])
        if email.blank? || password.blank? || password_confirmation.blank?
          render json: { error: "Email, password, and password confirmation are required" }, status: :unprocessable_content
          return
        end
        return if reject_disposable_email(email)

        user = User.new(email: email, password: password, password_confirmation: password_confirmation, name: name)
        # A soft-deleted account keeps its row (User has a `deleted_at: nil`
        # default scope) but still holds the unique index on `email`, so
        # `validatable` sees no conflict and the INSERT is what fails. Same
        # rescue as `email_signup` — without it this path 500s.
        begin
          saved = user.save
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Email has already been taken", error_code: "email_taken" }, status: :unprocessable_content
          return
        end
        if saved
          Rails.logger.info "New user signed up: #{user.email} at #{Time.now}"
          # result = Stripe::Customer.create({ email: user.email })
          if platform != "ios" && platform != "android"
            result = User.create_stripe_customer(user.email)
            user.stripe_customer_id = result
          else
            Rails.logger.warn "Mobile platform sign up detected for user #{user.email}, skipping Stripe customer creation for platform: #{platform}"
          end
          if params["plan_type"] && params["plan_type"] == "partner_pro"
            user.plan_type = "partner_pro"
            user.plan_status = "active"
            user.role = "partner"
            User.handle_new_partner_pro_subscription(user, params["plan_type"])
          end

          sign_in user
          user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
          user.ensure_minimum_communicator_slot!
          user.record_signup_context!(platform: platform, method: "standard", ref: params[:ref])
          user.notify_admin_of_signup!
          # Verification email. The user is already signed in — verification
          # gates the welcome tokens, never app access. See
          # drafts/2026-07-26-email-verification-design.md.
          # Best-effort: the user is already persisted (and signed in above),
          # so a hiccup here must not 500 the request and strand a created
          # account. queue_adapter is :sidekiq, so deliver_later enqueues to
          # Redis synchronously in this request — a Redis blip would otherwise
          # raise here with nothing rescuing it. A user left without a token
          # can recover via the resend-verification endpoint (later task),
          # which re-generates the token — a missing token is recoverable, a
          # 500 response is not.
          begin
            user.generate_email_verification_token!
            UserMailer.verify_email(user).deliver_later
          rescue => e
            Rails.logger.error "sign_up: email verification setup failed for #{user.email}: #{e.class}: #{e.message} — continuing; user can request a new verification email"
          end
          if user.role == "partner"
            user.send_partner_welcome_email
          end
          # Audience upsert BEFORE the journey trigger: a journey can only be
          # triggered for a contact that already exists, and Sidekiq runs these
          # concurrently. Enqueue order isn't a guarantee — MailchimpService
          # #trigger_journey still upserts-and-retries when it loses the race —
          # but there's no reason to hand the trigger a head start.
          MailchimpEventJob.perform_async(user.id, "sign_up")
          if params["plan_type"] != "partner_pro" && user.should_send_welcome_email?
            user.send_welcome_email("free")
            MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "welcome" })
          end
          PosthogService.capture_for_user(user, "user_signed_up", properties: {
            signup_method: "standard",
            plan_type: user.plan_type,
            platform: platform.presence || "web",
            signup_ref: user.settings&.dig("signup_ref"),
          })
          render json: { token: user.authentication_token, user: user.api_view }
        else
          # `error_code` is additive — the message keeps carrying every
          # validation failure verbatim, so an older client is unaffected. It
          # lets the signup form pivot a returning user to sign-in instead of
          # printing a raw validation string. Matches `email_signup`'s contract.
          email_taken = user.errors.details[:email].any? { |detail| detail[:error] == :taken }
          body = { error: user.errors.full_messages.join(", ") }
          body[:error_code] = "email_taken" if email_taken
          render json: body, status: :unprocessable_content
        end
      end

      # Email-only signup for the paid-intent path (frictionless paid signup,
      # itty-bitty-frontend#367). Creates a passwordless account via invite!
      # and signs the user in; password is set later via set_password or the
      # welcome email's magic link. Free/partner/demo/myspeak signups keep
      # using sign_up.
      def email_signup
        email = params[:email].to_s.strip.downcase
        platform = params["platform"] || ""

        # invite! saves with validate: false, so email format must be checked here.
        unless Devise.email_regexp.match?(email)
          render json: { error: "A valid email is required" }, status: :unprocessable_content
          return
        end
        return if reject_disposable_email(email)

        if User.exists?(email: email)
          render json: { error: "Email has already been taken", error_code: "email_taken" }, status: :unprocessable_content
          return
        end

        begin
          user = User.invite!(email: email, skip_invitation: true)
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Email has already been taken", error_code: "email_taken" }, status: :unprocessable_content
          return
        end
        unless user.persisted?
          render json: { error: user.errors.full_messages.join(", ") }, status: :unprocessable_content
          return
        end
        # The raw token only exists in memory on this instance — capture it for
        # the welcome email's magic link. Never rendered to the client.
        raw_invitation_token = user.raw_invitation_token

        if platform != "ios" && platform != "android"
          # Best-effort: the user is already persisted (invite! above), so a
          # Stripe hiccup here must not 500 the request — that would strand a
          # created account and the frontend would fall back to the full
          # sign-up form, which then fails with "email taken". Checkout and the
          # billing portal lazily ensure the customer via ensure_stripe_customer!.
          begin
            user.update(stripe_customer_id: User.create_stripe_customer(user.email))
          rescue => e
            Rails.logger.error "email_signup: Stripe customer creation failed for #{user.email}: #{e.message} — continuing; customer will be ensured at checkout"
          end
        else
          Rails.logger.warn "Mobile platform email signup for user #{user.email}, skipping Stripe customer creation for platform: #{platform}"
        end

        sign_in user
        user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
        user.ensure_minimum_communicator_slot!
        user.record_signup_context!(platform: platform, method: "email_only", ref: params[:ref])
        user.notify_admin_of_signup!
        # Verification email. The user is already signed in — verification
        # gates the welcome tokens, never app access. See
        # drafts/2026-07-26-email-verification-design.md.
        # Best-effort: the user is already persisted (and signed in above),
        # so a hiccup here must not 500 the request and strand a created
        # account. queue_adapter is :sidekiq, so deliver_later enqueues to
        # Redis synchronously in this request — a Redis blip would otherwise
        # raise here with nothing rescuing it. A user left without a token
        # can recover via the resend-verification endpoint, which
        # re-generates the token — a missing token is recoverable, a 500
        # response is not.
        begin
          user.generate_email_verification_token!
          UserMailer.verify_email(user).deliver_later
        rescue => e
          Rails.logger.error "email_signup: email verification setup failed for #{user.email}: #{e.class}: #{e.message} — continuing; user can request a new verification email"
        end
        # email_signup is the paid-intent path: no plan picked yet, so send a
        # plan-neutral receipt now. The real plan welcome ships from the Stripe
        # webhook once trial/active. The Mailchimp `welcome` journey is still
        # enqueued here (follow-up: make journey plan-aware too).
        # Audience upsert first — see the note in #sign_up.
        MailchimpEventJob.perform_async(user.id, "sign_up")
        if user.should_send_welcome_receipt_email?
          user.send_welcome_receipt_email(raw_invitation_token: raw_invitation_token)
          MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "welcome" })
        end
        PosthogService.capture_for_user(user, "user_signed_up", properties: {
          signup_method: "email_only",
          plan_type: user.plan_type,
          platform: platform.presence || "web",
          signup_ref: user.settings&.dig("signup_ref"),
        })
        render json: { token: user.authentication_token, user: user.api_view }
      end

      # Sets the initial password on a passwordless (invited) account.
      # Authenticated — not in the skip_before_action list. Must go through
      # accept_invitation! while an invitation is pending: devise_invitable's
      # valid_password? returns nil while invitation_token is present, so a
      # plain update would store a password the user can never sign in with.
      def set_password
        # Only pending invites qualify — anyone else already has a working
        # password (devise_invitable assigns a random one on invite!, so
        # encrypted_password.present? can't tell the two apart).
        unless current_user.invited_to_sign_up?
          render json: { error: "Password already set", error_code: "password_already_set" }, status: :unprocessable_content
          return
        end
        current_user.password = params[:password]
        current_user.password_confirmation = params[:password_confirmation]
        saved = current_user.accept_invitation!
        if saved && current_user.errors.empty?
          render json: { user: current_user.api_view }
        else
          render json: { error: current_user.errors.full_messages.join(", ") }, status: :unprocessable_content
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
              user.setup_free_limits
              user.save!
            end
          end
          # Self-heal a stranded plan (paid plan_type + non-paying status) with
          # no Stripe call — safety net for missed/out-of-order downgrade
          # webhooks so the user lands on Free with credits instead of stuck at
          # 0. No-op for healthy accounts; rescues internally.
          user.reconcile_stranded_plan!
          sign_in user
          user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
          user.ensure_minimum_communicator_slot!
          MailchimpEventJob.perform_async(user.id, "sign_in")
          PosthogService.capture_for_user(user, "user_signed_in", properties: {
            plan_type: user.plan_type,
          })
          render json: { token: user.authentication_token, user: user.api_view }
        else
          Rails.logger.warn "Failed sign in attempt for email: #{params[:email]} at #{Time.now}"
          render json: { error: error_message }, status: :unauthorized
        end
      end

      # Google sign-in (Phase 1 of social sign-in). The frontend obtains a
      # Google ID token client-side and posts it here for server-side
      # verification — this endpoint never sees a Google client secret.
      def google
        id_token = params[:id_token] || (params[:auth] && params[:auth][:id_token])
        platform = params["platform"] || ""

        result = GoogleIdTokenVerifier.verify(id_token)
        unless result
          render json: { error: "Invalid or expired Google sign-in token" }, status: :unauthorized
          return
        end

        user = User.find_by(provider: "google", uid: result.sub)
        is_new_user = false

        if user.nil?
          user = User.find_by(email: result.email)
          if user
            # Auto-link by email — mirrors the self-healing email-match
            # pattern used for the Stripe customer.created webhook. No
            # confirmation step: a Google-verified email is sufficient proof.
            user.update!(provider: "google", uid: result.sub)
          else
            is_new_user = true
            user = User.invite!(email: result.email, provider: "google", uid: result.sub, skip_invitation: true)
            unless user.persisted?
              render json: { error: user.errors.full_messages.join(", ") }, status: :unprocessable_content
              return
            end
          end
        end

        if user.locked?
          render json: { error: "Your account is locked. Please contact support." }, status: :unauthorized
          return
        end

        # Google's own verification counts as sufficient proof — no separate
        # verification email needed, unlike password signups.
        user.mark_email_verified!
        user.reconcile_stranded_plan!

        if is_new_user && platform != "ios" && platform != "android"
          begin
            user.update(stripe_customer_id: User.create_stripe_customer(user.email))
          rescue => e
            Rails.logger.error "auths#google: Stripe customer creation failed for #{user.email}: #{e.message} — continuing; customer will be ensured at checkout"
          end
        end

        sign_in user
        user.update(last_sign_in_at: Time.now, last_sign_in_ip: request.remote_ip)
        user.ensure_minimum_communicator_slot!

        if is_new_user
          user.record_signup_context!(platform: platform, method: "google", ref: params[:ref])
          user.notify_admin_of_signup!
          # Audience upsert first — see the note in #sign_up.
          MailchimpEventJob.perform_async(user.id, "sign_up")
          if user.should_send_welcome_email?
            user.send_welcome_email("free")
            MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "welcome" })
          end
          PosthogService.capture_for_user(user, "user_signed_up", properties: {
            signup_method: "google",
            plan_type: user.plan_type,
            platform: platform.presence || "web",
            signup_ref: user.settings&.dig("signup_ref"),
          })
        else
          MailchimpEventJob.perform_async(user.id, "sign_in")
          PosthogService.capture_for_user(user, "user_signed_in", properties: {
            plan_type: user.plan_type,
          })
        end

        # This one endpoint both signs up and signs in, so the client cannot
        # otherwise tell a brand-new account from a returning customer — and it
        # matters: the frontend sends new accounts to /onboarding, which is the
        # plan picker, where selecting Free (or the "Maybe later" skip) posts
        # plan_key: "free". Landing a returning customer there was one click
        # from a downgrade. Without this flag the frontend has to infer it from
        # plan/board/communicator counts.
        render json: {
          token: user.authentication_token,
          user: user.api_view,
          is_new_user: is_new_user,
        }
      end

      def forgot_password
        user = User.find_by(email: params[:email])
        if user
          reset_token = user.send_reset_password_instructions
          user.update(reset_password_token: reset_token)
        end
        render json: { message: "If that email address is registered, you will receive password reset instructions shortly." }
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
          @current_user.reconcile_stranded_plan!
          @view = @current_user.api_view
          render json: { user: @view }
        else
          @current_user = user_from_token
          if @current_user
            @current_user.reconcile_stranded_plan!
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

      # Renders the rejection and returns true when the address is disposable,
      # so callers can `return if reject_disposable_email(email)`. Shared by
      # both signup actions — one message, one place to change it.
      def reject_disposable_email(email)
        return false unless DisposableEmailDomains.disposable?(email)

        render json: { error: "Please use a permanent email address — we need to be able to reach you about your account." },
               status: :unprocessable_content
        true
      end
    end
  end
end
