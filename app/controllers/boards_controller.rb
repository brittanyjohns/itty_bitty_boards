class BoardsController < ApplicationController
  before_action :authenticate_user!

  before_action :set_board, only: %i[ show edit update destroy build add_multiple_images associate_image remove_image ]

  # GET /boards or /boards.json
  def index
    if current_user.admin?
      @boards = Board.all.order(created_at: :desc).page params[:page]
    else
      @boards = current_user.boards.non_menus.order(created_at: :desc).page params[:page]
    end
  end

  # GET /boards/1 or /boards/1.json
  def show
    redirect_back_or_to root_url unless current_user.admin? || current_user.id == @board.user_id
  end

  # GET /boards/new
  def new
    @board = Board.new
    @board.user = current_user
    @board.parent_id = params[:parent_id]
    @board.parent_type = params[:parent_type]
  end

  # GET /boards/1/edit
  def edit
  end

  # POST /boards or /boards.json
  def create
    @board = Board.new(board_params)
    @board.user = current_user
    @board.parent_id = params[:parent_id] || current_user.id
    @board.parent_type = params[:parent_type] || "User"

    respond_to do |format|
      if @board.save
        format.html { redirect_to board_url(@board), notice: "Board was successfully created." }
        format.json { render :show, status: :created, location: @board }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    respond_to do |format|
      if @board.update(board_params)
        format.html { redirect_to board_url(@board), notice: "Board was successfully updated." }
        format.json { render :show, status: :ok, location: @board }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  def build
    if params[:image_ids].present?
      image_ids = params[:image_ids].split(",").map(&:to_i)
      @image_ids_to_add = image_ids - @board.image_ids
    end
    if params[:query].present?
      @query = params[:query]
      @remaining_images = @board.remaining_images.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page(params[:page]).per(20)
    else
      @remaining_images = @board.remaining_images.order(label: :asc).page(params[:page]).per(20)
    end

    if turbo_frame_request?
      render partial: "select_images", locals: { images: @remaining_images }
    else
      render :build
    end
  end

  def add_multiple_images
    if params[:image_ids].present?
      @image_ids = params[:image_ids]
      puts "\n\n****image_ids: #{@image_ids}\n\n"
      @image_ids.each do |image_id|
        @board.add_image(image_id)
      end
    else
      puts "no image_ids"
    end
    redirect_back_or_to build_board_path(@board)
  end

  def associate_image
    image = Image.find(params[:image_id])

    unless @board.images.include?(image)
      new_board_image = @board.board_images.new(image: image)
      unless new_board_image.save
        Rails.logger.debug "new_board_image.errors: #{new_board_image.errors.full_messages}"
      end
    end

    redirect_back_or_to @board
  end

  def remove_image
    image = Image.find(params[:image_id])
    @board.images.delete(image)
    redirect_back_or_to @board
  end

  # DELETE /boards/1 or /boards/1.json
  def destroy
    @board.destroy!

    respond_to do |format|
      format.html { redirect_to boards_url, notice: "Board was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_board
      @board = Board.includes(board_images: { image: :docs }).find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def board_params
      params.require(:board).permit(:user_id, :name, :parent_id, :parent_type, :description)
    end
end
