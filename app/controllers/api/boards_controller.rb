class Api::BoardsController < ApplicationController
  before_action :set_board, only: %i[show]

  skip_before_action :authenticate_user!, only: %i[index show]

  # GET /boards or /boards.json
  def index
    @boards = Board.all
    @boards_with_images = @boards.map do |board|
      {
        id: board.id,
        name: board.name,
        user_id: board.user_id,
        images: board.images.map do |image|
          puts "image: #{image.inspect}"
          {
            id: image.id,
            label: image.label,
            url: image.main_doc&.image_url || "",
            private: image.private,
          }
        end,
      }
    end

    render json: @boards_with_images
  end

  # GET /boards/1
  def show
    payload = {
      id: @board.id,
      name: @board.name,
      user_id: @board.user_id,
      images: @board.images.map do |image|
        {
          id: image.id,
          label: image.label,
          url: image.main_doc&.image_url || "",
          private: image.private,
        }
      end,
    }
    render json: payload
  end

  private

  def set_board
    @board = Board.includes(:images).find(params[:id])
  end
end
