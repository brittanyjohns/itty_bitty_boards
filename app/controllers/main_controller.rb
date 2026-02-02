class MainController < ApplicationController
  def index
    render json: { status: "API is running", version: "1.0", status_code: 200 }
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
