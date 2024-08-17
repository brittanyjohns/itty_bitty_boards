class API::AuditsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!

  def word_click
    user = current_user || current_child.user
    unless user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      timestamp: params[:timestamp],
      user_id: user.id,
      board_id: params[:boardId],
      team_id: user.current_team_id,
      child_account_id: current_child&.id,
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
      puts "params[:account_id]: #{params[:account_id]}"
      @word_events = WordEvent.where(child_account_id: params[:account_id])
    else
      @word_events = WordEvent.all.limit(200)
    end
    render json: @word_events
  end
end
