class BoardsChannel < ApplicationCable::Channel
  def subscribed
    board_id = params["board_id"].to_s
    # TODO: Add authorization
    # reject unless current_account&.can_view_board?(board_id)
    stream_from "boards:#{board_id}"
  end
end
