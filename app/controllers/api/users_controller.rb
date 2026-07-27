class API::UsersController < API::ApplicationController
  # Clicked from an email client, which carries no bearer token.
  skip_before_action :authenticate_token!, only: %i[verify_email]

  before_action :set_user, only: %i[ show update_settings destroy update ]

  # GET /users or /users.json
  def index
    if current_user&.admin?
      @users = User.all.order(created_at: :desc)
    else
      @users = [current_user]
    end
    render json: @users.map(&:api_view)
  end

  # GET /users/1 or /users/1.json
  def show
    unless current_user&.admin? || current_user == @user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    if @user.locked?
      @user.settings["locked"] = true
    end
    render json: @user.api_view
  end

  def update
    @user = User.find(params[:id])
    @user.name = user_params[:name]

    if @user.save
      render json: @user, status: :ok
    else
      render json: @user.errors, status: :unprocessable_content
    end
  end

  def set_password
    @user = current_user

    password = params[:password]
    password_confirmation = params[:password_confirmation]
    if password != password_confirmation
      render json: { error: "Password confirmation does not match" }, status: :unprocessable_content
      return
    end
    @user.password = password
    @user.password_confirmation = password_confirmation
    @user.force_password_reset = false
    # Invited accounts must accept the invitation here: devise_invitable's
    # valid_password? returns nil while invitation_token is present, so a
    # plain save would store a password the user can never sign in with.
    saved = @user.invited_to_sign_up? ? @user.accept_invitation! : @user.save
    if saved && @user.errors.empty?
      render json: { success: true }, status: :ok
    else
      render json: @user.errors, status: :unprocessable_content
    end
  end

  def update_email
    unless current_user.valid_password?(params[:current_password])
      return render json: { error: "Current password is incorrect" }, status: :unauthorized
    end
    new_email = params[:email].to_s.strip.downcase

    if new_email.blank?
      return render json: { error: "Email can't be blank" }, status: :unprocessable_content
    end

    if new_email == current_user.email
      return render json: {
                      message: "That is already your current email.",
                      email: current_user.email,
                    }, status: :ok
    end

    if User.where.not(id: current_user.id).exists?(email: new_email) ||
       User.where.not(id: current_user.id).exists?(unconfirmed_email: new_email)
      return render json: { error: "Email is already taken" }, status: :unprocessable_content
    end

    if current_user.update(unconfirmed_email: new_email)
      token = SecureRandom.hex(16)
      if current_user.update(confirmation_token: token, confirmation_sent_at: Time.current)
        UserMailer.confirm_update_email(current_user).deliver_later
        render json: {
                 message: "Confirmation email sent to #{new_email}. Your current email will stay active until you confirm.",
                 current_email: current_user.email,
                 pending_email: current_user.unconfirmed_email,
               }, status: :ok
      else
        render json: { error: "Failed to update email" }, status: :unprocessable_content
      end
    else
      render json: { errors: current_user.errors.full_messages }, status: :unprocessable_content
    end
  end

  def confirm_email_change
    token = params[:confirmation_token]
    user = User.find_by(confirmation_token: token)

    if user.nil? || user.confirmation_token != token
      return render json: { error: "Invalid or expired token" }, status: :unprocessable_content
    end
    user.email = user.unconfirmed_email
    user.unconfirmed_email = nil
    user.confirmation_token = nil
    user.confirmed_at = Time.current
    if user.save
      render json: { message: "Email change confirmed", email: user.email }, status: :ok
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_content
    end
  end

  # Signup email verification. Unauthenticated — the link arrives in an inbox.
  # Distinct from confirm_email_change, which promotes a pending *change* to an
  # existing account's address.
  def verify_email
    token = params[:token].to_s
    user = token.present? ? User.find_by(email_verification_token: token) : nil

    if user.nil?
      return render json: { error: "That confirmation link is no longer valid. Send yourself a new one from your dashboard." },
                    status: :unprocessable_content
    end

    # Already verified — a double-click, or an email security scanner that
    # prefetched the link before the user got to it. Report success: the
    # account is fine, and an error would alarm someone who did nothing wrong.
    # Checked BEFORE expiry so a verified account never sees an error here.
    if user.email_verified?
      return render json: {
                      message: "Your email is already confirmed. Your free image credits are ready to use.",
                      email_verified: true,
                    }, status: :ok
    end

    unless user.email_verification_token_valid?
      return render json: { error: "That confirmation link has expired. Send yourself a new one from your dashboard." },
                    status: :unprocessable_content
    end

    user.mark_email_verified!

    render json: {
             message: "Your email is confirmed. Your free image credits are ready to use.",
             email_verified: true,
           }, status: :ok
  end

  # Resends the signup verification email. Throttled in the model layer via
  # email_verification_sent_at so the cooldown survives across app instances
  # (rack-attack's per-IP counters would not help a user on a shared IP).
  def resend_email_verification
    if current_user.email_verified?
      return render json: { error: "Your email is already confirmed." },
                    status: :unprocessable_content
    end

    unless current_user.can_resend_email_verification?
      retry_after = (current_user.email_verification_sent_at +
                     User::EMAIL_VERIFICATION_RESEND_INTERVAL - Time.current).ceil
      return render json: {
                      error: "We just sent one — check your inbox, then try again in a moment.",
                      retry_after: retry_after,
                    }, status: :too_many_requests
    end

    # The whole point of this request is sending an email, so an enqueue
    # failure here can't be reported as success — that would be a lie the
    # user discovers when nothing arrives, and it's why this endpoint
    # deliberately diverges from sign_up/email_signup's best-effort verification
    # email (those succeed regardless — account creation is the primary
    # purpose and a missing token is recoverable from here).
    #
    # A DB transaction can't give this atomicity: queue_adapter is :sidekiq,
    # so deliver_later pushes to Redis immediately, and Redis isn't a
    # participant in any Postgres transaction wrapped around it. Wrapping one
    # around the token write used to create two hazards instead of removing
    # one — a worker could dequeue and render the mailer against the
    # not-yet-committed (stale) token before commit, or the push could
    # succeed and then the commit fail, leaving a queued job for a token that
    # was never persisted.
    #
    # So: sequence instead of rolling back. Mint the token value, hand it
    # directly to the mailer (which delivers it as-is rather than reading it
    # back off the user — see UserMailer#verify_email), and only persist the
    # token + email_verification_sent_at — which starts the cooldown — after
    # the enqueue call itself has returned without raising.
    token = SecureRandom.hex(16)
    begin
      UserMailer.verify_email(current_user, token).deliver_later
    rescue => e
      Rails.logger.error "resend_email_verification: mailer enqueue failed for #{current_user.email}: #{e.class}: #{e.message}"
      return render json: { error: "Couldn't send the verification email. Please try again in a moment." },
                    status: :service_unavailable
    end

    begin
      current_user.persist_email_verification_token!(token)
    rescue => e
      # Rare: the email is already out (with `token` embedded in its link),
      # but we failed to save that same token to the user row, so the link
      # would 404. Still the honest response — nothing usable was persisted.
      Rails.logger.error "resend_email_verification: token persist failed after enqueue for #{current_user.email}: #{e.class}: #{e.message}"
      return render json: { error: "Couldn't send the verification email. Please try again in a moment." },
                    status: :service_unavailable
    end

    render json: { message: "Confirmation email sent to #{current_user.email}." }, status: :ok
  end

  def resend_email_confirmation
    pending_email = current_user.unconfirmed_email

    if pending_email.blank?
      return render json: { error: "No pending email change." }, status: :unprocessable_content
    end

    # current_user.send_confirmation_instructions
    if current_user.confirmation_token.nil? || current_user.confirmation_sent_at < 1.hour.ago
      token = SecureRandom.hex(16)
      current_user.update(confirmation_token: token, confirmation_sent_at: Time.current)
    end
    UserMailer.confirm_update_email(current_user).deliver_later

    render json: {
      message: "Confirmation email resent to #{pending_email}.",
    }, status: :ok
  end

  def cancel_email_change
    if current_user.unconfirmed_email.present?
      current_user.update_column(:unconfirmed_email, nil)
      current_user.update_column(:confirmation_token, nil)
      current_user.update_column(:confirmation_sent_at, nil)

      render json: { message: "Pending email change canceled." }, status: :ok
    else
      render json: { error: "No pending email change." }, status: :unprocessable_content
    end
  end

  # User-settable keys via PATCH/PUT update_settings. Anything outside this
  # list (including Rails' controller/action/id/format params, plan/limit keys,
  # and internal flags) is ignored, so the endpoint can't pollute or escalate
  # the settings blob. Plan limits are owned by the webhook/admin paths, not here.
  USER_SETTABLE_SETTINGS_KEYS = %w[
    wait_to_speak disable_audit_logging enable_image_display enable_text_display
    show_labels show_tutorial disable_scroll is_caregiver disable_notifications
    snap_to_screen display_follows_preview timezone language
    phrase_board_id opening_board_id startup_board_group_id predictive_board_id
    image_style
  ].freeze
  USER_SETTABLE_VOICE_KEYS = %w[name speed pitch rate volume language].freeze
  # Keys that only accept a known set of values. Images::PromptBuilder already
  # ignores an unrecognized style, but there's no reason to store junk.
  USER_SETTABLE_ENUM_SETTINGS = {
    "image_style" => Images::PromptBuilder::STYLE_NAMES,
  }.freeze

  # PATCH/PUT /users/1 or /users/1.json
  def update_settings
    unless current_user&.admin? || current_user == @user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    @user.settings ||= {}

    # Partial update: merge only whitelisted keys, leaving the rest of the
    # settings blob intact (the frontend relies on this deep-merge — e.g. the
    # language switcher sends just `{ voice: { language } }`).
    USER_SETTABLE_SETTINGS_KEYS.each do |key|
      next if params[key].nil?

      allowed = USER_SETTABLE_ENUM_SETTINGS[key]
      next if allowed && !allowed.include?(params[key].to_s)

      @user.settings[key] = params[key]
    end

    if params[:voice].present?
      voice = (@user.settings["voice"] || {}).merge(
        params.require(:voice).permit(*USER_SETTABLE_VOICE_KEYS).to_h
      )
      @user.settings["voice"] = voice
    end

    respond_to do |format|
      if @user.save
        format.json { render json: @user.api_view, status: :ok }
      else
        format.json { render json: @user.errors, status: :unprocessable_content }
      end
    end
  end

  # Required for Apple Store account deletion - sends email with token to confirm deletion

  def send_delete_account_email
    @user = current_user
    expire_time = 2.hours.from_now
    @user.delete_account_token = SecureRandom.hex(16)
    @user.delete_account_token_expires_at = expire_time
    @user.save!
    UserMailer.delete_account_email(@user).deliver_later
    render json: { success: true }, status: :ok
  end

  def delete_account
    @user = current_user
    # TODO - Apple doesn't allow for confirmation emails to be sent before deletion
    # so we skip token verification for Apple users

    # if @user.nil? || @user.email != params[:email] || @user.delete_account_token != params[:token]
    #   render json: { error: "Invalid or expired token" }, status: :unprocessable_content
    #   return
    # end

    # if @user.nil? || @user.delete_account_token_expires_at.nil? || @user.delete_account_token_expires_at < Time.current
    #   render json: { error: "Invalid or expired token" }, status: :unprocessable_content
    #   return
    # end
    if @user.admin?
      render json: { error: "Admin accounts cannot be deleted via this method" }, status: :forbidden
      return
    end
    if @user.soft_delete_account!(reason: "user_requested", actor_id: @user.id)
      render json: { success: true }, status: :ok
    else
      render json: { error: "Failed to delete account" }, status: :unprocessable_content
    end
  end

  # DELETE /users/1 or /users/1.json
  def destroy
    unless current_user&.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    @user.destroy!

    render json: { success: true }
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_user
    @user = User.find(params[:id])
  end

  def restrict
    redirect_to root_path unless current_user&.admin?
  end

  # Only allow a list of trusted parameters through.
  def user_params
    # :plan_type is intentionally NOT permitted here — a user must not be able to
    # set their own paid tier via mass-assignment (payment bypass). Plan state is
    # owned by the Stripe/RevenueCat webhook and admin paths. #update only reads
    # :name today; dropping :plan_type also closes the latent hole if a future
    # edit switches to `@user.update(user_params)` (#27).
    params.require(:user).permit(:name, :email, :base_words,
                                 voice: [:name, :speed, :pitch, :rate, :volume, :language])
  end
end
