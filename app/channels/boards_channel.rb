class BoardsChannel < ApplicationCable::Channel
  def subscribed
    board_id = params["board_id"].to_s
    reject unless current_user&.can_view_board?(board_id)
    stream_from "boards:#{board_id}"
  end
end
