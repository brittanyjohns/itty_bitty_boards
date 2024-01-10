class BoardImagesController < ApplicationController
  before_action :authenticate_user!

  before_action :set_board_image, only: %i[ show edit update destroy ]

  # GET /board_images or /board_images.json
  def index
    @board_images = BoardImage.all
  end

  # GET /board_images/1 or /board_images/1.json
  def show
  end

  # GET /board_images/new
  def new
    @board_image = BoardImage.new
  end

  # GET /board_images/1/edit
  def edit
  end

  # POST /board_images or /board_images.json
  def create
    @board_image = BoardImage.new(board_image_params)

    respond_to do |format|
      if @board_image.save
        format.html { redirect_to board_image_url(@board_image), notice: "Board image was successfully created." }
        format.json { render :show, status: :created, location: @board_image }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @board_image.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /board_images/1 or /board_images/1.json
  def update
    respond_to do |format|
      if @board_image.update(board_image_params)
        format.html { redirect_to board_image_url(@board_image), notice: "Board image was successfully updated." }
        format.json { render :show, status: :ok, location: @board_image }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @board_image.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /board_images/1 or /board_images/1.json
  def destroy
    @board_image.destroy!

    respond_to do |format|
      format.html { redirect_to board_images_url, notice: "Board image was successfully destroyed." }
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
      params.require(:board_image).permit(:board_id, :image_id, :position)
    end
end
