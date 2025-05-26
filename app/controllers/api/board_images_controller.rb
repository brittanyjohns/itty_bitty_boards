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
    render json: @board_image.api_view(current_user)
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
    updatedData = @board_image.data.merge(data.to_unsafe_h) if data

    @board_image.data = updatedData if updatedData
    if @board_image.update(board_image_params)
      @board_image.board.touch
      render json: @board_image.api_view(current_user)
    else
      render json: @board_image.errors, status: :unprocessable_entity
    end
  end

  def update_multiple
    puts "Updating multiple board images: #{params.inspect}"
    board_image_ids = params[:board_image_ids]
    @board = Board.find(params[:board_id])
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_entity
      return
    end
    board_images = BoardImage.where(id: board_image_ids, board_id: @board.id)
    if board_images.empty?
      render json: { error: "No board images found" }, status: :unprocessable_entity
      return
    end
    payload = params[:payload]
    if payload.nil?
      render json: { error: "No payload provided" }, status: :unprocessable_entity
      return
    end
    bg_color = payload[:bg_color] if payload[:bg_color]
    text_color = payload[:text_color] if payload[:text_color]
    hide_images = payload[:hide_images] if payload[:hide_images]
    make_static = payload[:make_static] if payload[:make_static]
    results = []
    board_images.each do |board_image|
      if !bg_color.blank?
        board_image.bg_color = bg_color
      end
      if !text_color.blank?
        board_image.text_color = text_color
      end
      if hide_images
        board_image.hidden = true
      else
        board_image.hidden = false
      end
      if make_static
        board_image.predictive_board_id = nil
      end
      if board_image.save
        results << true
      else
        results << false
      end
    end
    # @board.touch
    # @board.reload

    if results.all?
      puts "All board images updated successfully"
      render json: { board: @board.api_view_with_predictive_images(current_user, nil, true) }
    else
      render json: { error: "Failed to update some board images" }, status: :unprocessable_entity
    end
  end

  def remove_multiple
    board_image_ids = params[:board_image_ids]
    @board = Board.find(params[:board_id])
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_entity
      return
    end
    board_images = BoardImage.where(id: board_image_ids, board_id: @board.id)
    if board_images.empty?
      render json: { error: "No board images found" }, status: :unprocessable_entity
      return
    end
    puts "Removing board images: #{board_images.inspect}"
    results = []
    board_images.each do |board_image|
      if board_image.destroy
        results << true
      else
        results << false
      end
    end
    if results.all?
      puts "All board images removed successfully"
      render json: { board: @board.api_view_with_predictive_images(current_user, nil, true) }
    else
      render json: { error: "Failed to remove some board images" }, status: :unprocessable_entity
    end
  end

  def move
    @board_id = params[:board_id].to_i
    @image_id = params[:image_id].to_i

    @board = Board.find(@board_id)
    if @board.nil?
      render json: { error: "Board not found" }, status: :unprocessable_entity
      return
    end

    @board_image = BoardImage.find_by(board_id: @board_id, image_id: @image_id)
    if @board_image.nil?
      render json: { error: "Board image not found" }, status: :unprocessable_entity
      return
    end
    @new_image = Image.find(params[:new_image_id]&.to_i)
    @board_image.image = @new_image
    if @new_image.user_id != current_user.id
      render json: { error: "You do not have permission to move this image" }, status: :unprocessable_entity
    end

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
    @board_image = BoardImage.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def board_image_params
    params.require(:board_image).permit(:board_id, :predictive_board_id,
                                        :image_id, :position, :voice, :bg_color,
                                        :text_color, :font_size, :border_color,
                                        :display_label,
                                        :layout, :status, :audio_url, :hidden)
  end
end
