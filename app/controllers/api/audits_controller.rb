class API::AuditsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!

  def word_click
    user = current_user || current_account.user
    unless user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    image = Image.find(params[:imageId]) if params[:imageId]
    unless image
      image = current_account.images.find_by(label: params[:word]) if current_account
      image = current_user.images.find_by(label: params[:word]) if current_user
    end

    # TODO - team tracking needs work - not using current_team_id anymore

    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      image_id: params[:imageId],
      timestamp: params[:timestamp],
      image_id: image&.id,
      user_id: user.id,
      board_id: params[:boardId],
      team_id: user.current_team_id, # current_team_id is not being set
      child_account_id: current_account&.id,
    }
    WordEvent.create(payload)
    render json: { message: "Word click recorded" }
  end

  def word_events
    if params[:user_id]
      @user = User.includes(:word_events).find(params[:user_id])
      @word_events = @user.word_events.limit(500)
      # @word_events = WordEvent.where(user_id: params[:user_id]).limit(200)
    elsif params[:account_id]
      @word_events = WordEvent.where(child_account_id: params[:account_id]).order(timestamp: :desc).limit(500)
    else
      @word_events = WordEvent.order(timestamp: :desc).limit(500)
    end
    render json: @word_events.order(created_at: :desc).map(&:api_view)
  end
end
