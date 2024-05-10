class API::AuditsController < API::ApplicationController
  before_action :authenticate_token!

  def word_click
    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      timestamp: params[:timestamp],
      user_id: current_user.id,
      board_id: params[:boardId],
      team_id: current_user.current_team_id,
    }
    WordEvent.create(payload)
    render json: { message: "Word click recorded" }
  end
end
