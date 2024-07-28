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
    @word_events = WordEvent.all.order(word: :asc).limit(200)
    render json: @word_events
  end
end
