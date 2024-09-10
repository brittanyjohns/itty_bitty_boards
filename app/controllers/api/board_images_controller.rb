class API::BoardImagesController < API::ApplicationController
  respond_to :json
  before_action :set_board_image, only: %i[ show edit update destroy ]

  # GET /board_images or /board_images.json
  def index
    @board_images = BoardImage.all
  end

  # GET /board_images/1 or /board_images/1.json
  def show
    render json: @board_image.api_view(current_user)
  end

  def by_image
    puts "by_image"
    @board_images = BoardImage.where(image_id: params[:image_id], board_id: params[:board_id])
    render json: @board_images.first&.api_view(current_user)
  end

  def save_layout
    @board_image = BoardImage.find(params[:id])
    layout = params[:layout]
    screen_size = params[:screen_size]
    @board_image.update_layout(layout, screen_size)
    render json: @board_image
  end

  def set_next_words
    @board_image = BoardImage.find(params[:id])
    new_next_words = params[:next_words]&.compact_blank
    puts "New next words: #{new_next_words} - #{@board_image.next_words}"
    if new_next_words.present?
      @board_image.next_words = new_next_words
      @board_image.create_next_images
      puts "BI- Next words: #{@board_image[:next_words]}"
      @board_image.save
    else
      SetNextWordsJob.perform_async(@board_image.id, "BoardImage")
    end

    if params[:run_job]
      puts "Running SetNextWordsJob.perform_async => #{params.inspect}"
      SetNextWordsJob.perform_async(@board_image.id, "BoardImage")
    end

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

  def predictive_images
    # begin
    @board_image = BoardImage.find(params[:id])

    puts "Predictive images for board image: #{@board_image.label} - mode: #{@board_image.mode}"

    if @board_image.mode == "dynamic" && @board_image.dynamic_board_id.present?
      @dynamic_board = Board.find(@board_image.dynamic_board_id)
      render json: @dynamic_board.api_view_with_images(current_user)
      return
    else
      render json: { error: "No dynamic board found for board image" }, status: :unprocessable_entity
    end
    # @next_images = @board_image.next_images.map do |ni|
    #   puts "Next Image: #{ni.inspect}"
    #   puts "Next Image: #{ni[:id]} - #{ni[:label]} - #{ni[:bg_color]} - #{ni[:src]} - #{ni[:audio_url]}"
    #   {
    #     id: ni[:id],
    #     label: ni[:label],
    #     bg_color: ni[:bg_color],
    #     src: ni[:src],
    #     audio: ni[:audio_url],
    #   }
    # end

    # render json: @next_images
  end

  def make_dynamic
    @board_image = BoardImage.find(params[:id])
    @board_image.make_dynamic
    @board_image.reload
    puts "Dynamic board: #{@board_image.inspect}"
    render json: @board_image.api_view(current_user)
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
