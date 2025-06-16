class API::AuditsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!, only: [:word_click, :word_events]

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
      @word_events = WordEvent.includes(:image, :board, :child_account).where(child_account_id: params[:account_id]).order(timestamp: :desc).limit(500)
    else
      @word_events = WordEvent.includes(:image, :board, :child_account).order(timestamp: :desc).limit(500)
    end
    render json: @word_events.order(created_at: :desc).map { |event|
      event.api_view(current_user || current_account.user)
    }
  end

  def public_word_click
    image = Image.find(params[:imageId]) if params[:imageId]
    board = Board.includes(:user).find(params[:boardId]) if params[:boardId]
    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      image_id: params[:imageId],
      timestamp: params[:timestamp],
      image_id: image&.id,
      user_id: board&.user&.id,
      board_id: params[:boardId],
      child_account_id: current_account&.id,
    }
    WordEvent.create(payload)
    render json: { message: "Word click recorded" }
  end
end
