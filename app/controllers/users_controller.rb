class UsersController < ApplicationController
  before_action :authenticate_user!
  # The legacy HTML admin pages (/users, /users/admin) list every account in the
  # system — admin-only, same as the /admin namespace. Gating happens in a
  # before_action, not inline in the action, so the body never runs for a caller
  # who shouldn't reach it. (#word_events has no route left, but is gated with
  # them so re-adding one can't quietly reopen it.)
  before_action :require_admin!, only: %i[index admin word_events]
  before_action :set_user, only: %i[show edit update]
  before_action :require_self_or_admin!, only: %i[show edit update]

  def index
    @users = User.all.order(created_at: :desc).page params[:page]
  end

  def admin
    @users = User.all.order(created_at: :desc).page params[:page]
    @beta_requests = BetaRequest.all.order(created_at: :desc).page params[:page]
    @messages = Message.all.order(created_at: :desc).page params[:page]
    @images = Image.with_artifacts.all.order(label: :desc).page params[:page]
    @docs = Doc.all.order(created_at: :desc).page params[:page]
    @boards = Board.all.order(name: :desc).page params[:page]
    @word_events = WordEvent.all.order(word: :asc).page params[:page]
  end

  def word_events
    @total_clicks = WordEvent.count
    @clicks_per_user = WordEvent.group(:user_id).count
    @most_clicked_words = WordEvent.group(:word).order("count_id DESC").count(:id)
    @most_common_previous_words = WordEvent.group(:previous_word).order("count_id DESC").count(:id)
    @clicks_over_time = WordEvent.group_by_day(:timestamp).count
  end

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

  def require_admin!
    deny! unless current_user&.admin?
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
