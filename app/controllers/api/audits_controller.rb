class API::AuditsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!

  def word_click
    user = current_user || current_account.user
    unless user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    # TODO - team tracking needs work - not using current_team_id anymore

    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      image_id: params[:imageId],
      timestamp: params[:timestamp],
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
      @user = User.find(params[:user_id])
      @word_events = @user.word_events.limit(200)
      # @word_events = WordEvent.where(user_id: params[:user_id]).limit(200)
    elsif params[:account_id]
      @word_events = WordEvent.where(child_account_id: params[:account_id])
    else
      @word_events = WordEvent.all.limit(200)
    end
    render json: @word_events.order(created_at: :desc)
  end
end
