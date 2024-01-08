class MainController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index]
  def index
    @boards = current_user.boards.order(created_at: :desc) if user_signed_in?
    @boards ||= Board.none
  end
end
