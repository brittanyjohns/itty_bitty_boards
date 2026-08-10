class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: %i[show edit update]
  before_action :require_self_or_admin!, only: %i[show edit update]

  # Admin listings live in the /admin namespace (Admin::DashboardController,
  # Admin::UsersController, Admin::WordEventsController). The actions that used
  # to duplicate them here (#index, #admin, #word_events) are gone, so what's
  # left is self-service profile only — there is no admin-only action here to
  # gate.

  def show
  end

  def remove_user_doc
    @user_doc = UserDoc.find(params[:id])
    return deny! unless current_user&.admin? || @user_doc.user_id == current_user&.id

    @user_doc.destroy
    redirect_back_or_to root_url
  end

  def edit
  end

  def update
    if @user.update(user_params)
      redirect_to user_path(@user), notice: "Successfully updated."
    else
      render "edit", alert: "There was an error updating the user.\nErrors: #{@user.errors.full_messages.join(", ")}"
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.require(:user).permit(:name, :base_words, settings: [:voice, :speed, :pitch, :rate, :volume, :language])
  end

  # A user's own profile is self-service ("Edit Profile" on /users/:id); every
  # other account is admin-only. `user_params` deliberately permits no role or
  # plan field, so this is the whole gate for the HTML profile pages.
  def require_self_or_admin!
    return if current_user&.admin? || current_user&.id == @user&.id

    deny!
  end

  # Always root, never `redirect_back_or_to` — bouncing a denied caller to its
  # referrer can ping-pong between two pages that both deny.
  def deny!
    redirect_to root_url, alert: "You are not authorized to perform this action."
  end
end
