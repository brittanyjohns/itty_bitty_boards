class MainController < ApplicationController
  def index
    @predefined_boards = Board.predefined.includes(:images).order(:name)
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
end
