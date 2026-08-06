module Admin
  class PlaceholdersController < Admin::ApplicationController
    def index
      @profiles = Profile.where(placeholder: true).order(created_at: :desc)
    end

    def create
      username = params[:username].presence || SecureRandom.hex(4)
      user_email = params[:user_email]

      if user_email.blank?
        redirect_to admin_dashboard_placeholders_path, alert: "Email is required."
        return
      end

      slug = username.parameterize
      if Profile.find_by(username: username) || Profile.find_by(slug: slug)
        redirect_to admin_dashboard_placeholders_path, alert: "This username has been taken. Please try again."
        return
      end

      existing_user = User.find_by(email: user_email)
      user = existing_user || User.create_from_email(user_email, nil, nil, slug)

      unless user
        redirect_to admin_dashboard_placeholders_path, alert: "Failed to invite user."
        return
      end

      # Passing a user here has generate_with_username immediately create a
      # communicator account and claim the profile to it (placeholder: false)
      # — this is a "create a MySpeak page for this user now" utility, not an
      # addition to the unclaimed placeholder list above.
      profile = Profile.generate_with_username(username, user)
      if profile
        redirect_to admin_dashboard_placeholders_path, notice: "Created and claimed a MySpeak profile \"#{profile.username}\" for #{user.email}."
      else
        redirect_to admin_dashboard_placeholders_path, alert: "Failed to generate placeholder — username may already be taken."
      end
    end
  end
end
