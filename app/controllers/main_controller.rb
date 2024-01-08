class MainController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index]
  def index
    @docs = current_user.docs
    @boards = current_user.boards.order(created_at: :desc)
  end
end
