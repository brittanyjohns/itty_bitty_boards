class BoardsController < ApplicationController
  before_action :authenticate_user!, except: %i[ locked ]
  after_action :verify_policy_scoped, only: :index

  before_action :set_board, only: %i[ show edit update destroy build add_multiple_images associate_image remove_image fullscreen locked ]
  layout "fullscreen", only: [:fullscreen]
  layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    @boards = policy_scope(Board)
    if params[:query].present?
      @query = params[:query]
      @boards = @boards.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc).page(params[:page]).per(20)
      @predefined_boards = Board.predefined.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc).page(params[:page]).per(20)
    else
      @boards = @boards.order(created_at: :desc).page(params[:page]).per(20)
      @predefined_boards = Board.predefined.order(created_at: :desc).page(params[:page]).per(20)
    end
    @shared_with_me = current_user.shared_with_me_boards.order(created_at: :desc).page(params[:page]).per(20)
  end

  # GET /boards/1 or /boards/1.json
  def show
    authorize @board
    # unless current_user.admin? || current_user.id == @board.user_id
    #   redirect_back_or_to root_url unless @board.predefined
    # end
  end

  def fullscreen
  end

  def locked
  end

  # GET /boards/new
  def new
    @board = Board.new
    @board.user = current_user
    @board.parent_id = params[:parent_id]
    @board.parent_type = params[:parent_type]
    @openai_prompt = OpenaiPrompt.new
  end

  # GET /boards/1/edit
  def edit
    authorize @board
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
        format.turbo_stream
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  def update_grid
    @board = Board.find(params[:id])
    @board.number_of_columns = params[:number_of_columns]
    @board.save!
    render json: { status: "ok", data: { number_of_columns: @board.number_of_columns } }
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
    @image = Image.find(params[:image_id])
    @board.images.delete(@image)
    respond_to do |format|
      # format.html { redirect_to @board, notice: "Image was successfully removed from board." }
      format.json { head :no_content }
      format.turbo_stream
    end
  end

  # DELETE /boards/1 or /boards/1.json
  def destroy
    @board.destroy!

    respond_to do |format|
      format.html { redirect_to boards_url, notice: "Board was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  def clone
    @board = Board.includes(:images).find(params[:id])
    @new_board = Board.new
    @new_board.description = @board.description
    @new_board.user = current_user
    @new_board.parent_id = current_user.id
    @new_board.parent_type = "User"
    @new_board.predefined = false
    @new_board.name = "Copy of " + @board.name
    @board.images.each do |image|
      @new_board.add_image(image.id)
    end
    @new_board.save!
    redirect_to board_url(@new_board), notice: "Board was successfully cloned."
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_board
      @board = Board.includes(board_images: { image: :docs }).find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def board_params
      params.require(:board).permit(:user_id, :name, :parent_id, :parent_type, :description, :number_of_columns, :predefined, :voice)
    end
end
