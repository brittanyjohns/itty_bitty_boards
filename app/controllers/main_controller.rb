class MainController < ApplicationController
  def index
    @predefined_boards = Board.predefined.includes(:images).order(:name)
    @beta_request = BetaRequest.new
  end

  def beta_request_form
    @beta_request = BetaRequest.new
  end

  def show_predefined
    @board = Board.includes(:images).find(params[:id])
  end

  def demo
  end

  def about
  end

  def contact
  end

  def faq
  end

  def privacy
  end

  def dashboard
    @boards = policy_scope(Board).includes(:images).order(:name)
    @user = current_user
  end
end
