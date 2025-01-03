class API::BoardImagesController < API::ApplicationController
  respond_to :json
  before_action :set_board_image, only: %i[ show update destroy ]

  # GET /board_images or /board_images.json
  def index
    @board_images = BoardImage.all
  end

  # GET /board_images/1 or /board_images/1.json
  def show
    render json: @board_image.api_view(current_user)
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

  # PATCH/PUT /board_images/1 or /board_images/1.json
  def update
    data = params[:board_image][:data]
    updatedData = @board_image.data.merge(data.to_unsafe_h)
    @board_image.data = updatedData
    if @board_image.save
      render json: @board_image.api_view(current_user)
    else
      render json: @board_image.errors, status: :unprocessable_entity
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
    puts "set_board_image"
    puts params
    @board_image = BoardImage.find(params[:id])
    puts "set_board_image done #{@board_image}"
  end

  # Only allow a list of trusted parameters through.
  def board_image_params
    params.require(:board_image).permit(:board_id, :image_id, :position, :voice, data: {})
  end
end
