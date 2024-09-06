class API::BoardImagesController < API::ApplicationController
  respond_to :json
  before_action :set_board_image, only: %i[ show edit update destroy ]

  # GET /board_images or /board_images.json
  def index
    @board_images = BoardImage.all
  end

  # GET /board_images/1 or /board_images/1.json
  def show
    render json: @board_image.api_view
  end

  def make_dynamic
    @board_image = BoardImage.find(params[:id])
    @board_image.make_dynamic
    render json: @board_image.api_view
  end

  def make_static
    @board_image = BoardImage.find(params[:id])
    @board_image.make_static
    render json: @board_image.api_view
  end

  def save_layout
    @board_image = BoardImage.find(params[:id])
    layout = params[:layout]
    screen_size = params[:screen_size]
    @board_image.update_layout(layout, screen_size)
    render json: @board_image
  end

  def move_up
    @board_image = BoardImage.find(params[:id])
    @board_image.move_higher
  end

  def move_down
    @board_image = BoardImage.find(params[:id])
    @board_image.move_lower
  end

  # GET /board_images/new
  def new
    @board_image = BoardImage.new
    @board = Board.find(params[:board_id])
  end

  # GET /board_images/1/edit
  def edit
  end

  # POST /board_images or /board_images.json
  def create
    @board_image = BoardImage.new(board_image_params)

    respond_to do |format|
      if @board_image.save
        format.json { render :show, status: :created, location: @board_image }
      else
        format.json { render json: @board_image.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /board_images/1 or /board_images/1.json
  def update
    respond_to do |format|
      if @board_image.update(board_image_params)
        format.json { render :show, status: :ok, location: @board_image }
      else
        format.json { render json: @board_image.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /board_images/1 or /board_images/1.json
  def destroy
    @board_image.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board_image
    @board_image = BoardImage.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def board_image_params
    params.require(:board_image).permit(:board_id, :image_id, :position, :voice)
  end
end
