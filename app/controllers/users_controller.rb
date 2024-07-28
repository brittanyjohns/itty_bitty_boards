class UsersController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_back_or_to root_url unless current_user.admin?
    @users = User.all.order(created_at: :desc).page params[:page]
  end

  def admin
    unless current_user.admin?
      redirect_back_or_to root_url
    end
    @users = User.all.order(created_at: :desc).page params[:page]
    @beta_requests = BetaRequest.all.order(created_at: :desc).page params[:page]
    @messages = Message.all.order(created_at: :desc).page params[:page]
    @images = Image.with_artifacts.all.order(label: :desc).page params[:page]
    @docs = Doc.all.order(created_at: :desc).page params[:page]
    @boards = Board.all.order(name: :desc).page params[:page]
    @word_events = WordEvent.all.order(word: :asc).page params[:page]
  end

  def word_events
    unless current_user.admin?
      redirect_back_or_to root_url
    end
    @total_clicks = WordEvent.count
    @clicks_per_user = WordEvent.group(:user_id).count
    @most_clicked_words = WordEvent.group(:word).order("count_id DESC").count(:id)
    @most_common_previous_words = WordEvent.group(:previous_word).order("count_id DESC").count(:id)
    @clicks_over_time = WordEvent.group_by_day(:timestamp).count
  end

  def show
    # redirect_back_or_to root_url unless current_user.admin? || current_user.id == params[:id].to_i
    @user = User.find(params[:id])
  end

  def remove_user_doc
    @user_doc = UserDoc.find(params[:id])
    @user_doc.destroy
    redirect_back_or_to root_url
  end

  def edit
    @user = User.find(params[:id])
  end

  def update
    @user = User.find(params[:id])
    if @user.update(user_params)
      redirect_to user_path(@user), notice: "Successfully updated."
    else
      render "edit", alert: "There was an error updating the user.\nErrors: #{user.errors.full_messages.join(", ")}"
    end
  end

  private

  def user_params
    params.require(:user).permit(:name, :base_words, settings: [:voice, :speed, :pitch, :rate, :volume, :language])
  end
end
