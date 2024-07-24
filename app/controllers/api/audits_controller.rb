class API::AuditsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_child_token!

  def word_click
    user = current_child.user
    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      timestamp: params[:timestamp],
      user_id: user.id,
      board_id: params[:boardId],
      team_id: user.current_team_id,
    }
    WordEvent.create(payload)
    render json: { message: "Word click recorded" }
  end
end
