class API::BoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json

  # before_action :authenticate_user!

  before_action :set_board, only: %i[ associate_image remove_image destroy ]
  # layout "fullscreen", only: [:fullscreen]
  # layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    if params[:query].present?
      @query = params[:query]
      @boards = current_user.boards.user_made.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
      @predefined_boards = current_user.boards.predefined.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
      @scenarios = current_user.boards.scenarios.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
      @shared_boards = current_user.shared_with_me_boards.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
    else
      @boards = current_user.boards.user_made.order(created_at: :desc)
      @predefined_boards = Board.predefined.order(created_at: :desc)
      @scenarios = current_user.boards.scenarios.order(created_at: :desc)
      @shared_boards = current_user.shared_with_me_boards.order(created_at: :desc)
    end
    puts "SHARED BOARDS: #{@shared_boards.count}"

    render json: { boards: @boards, predefined_boards: @predefined_boards, scenarios: @scenarios, shared_boards: @shared_boards }
  end

  def user_boards
    @boards = current_user.boards.user_made.order(created_at: :desc)

    render json: { boards: @boards }
  end

  # export interface PredictiveImage {
  #   id: string;
  #   src: string;
  #   label: string;
  #   next_images: PredictiveImage[];
  #   image_prompt?: string;
  #   audio?: string;
  #   docs?: ImageDoc[];
  #   display_doc?: ImageDoc;
  # }

  def predictive_index
    @boards = Board.includes(:images).predictive
    @predictive_boards = @boards.map do |board|
      {
        id: board.id,
        name: board.name,
        description: board.description,
        parent_type: board.parent_type,
        predefined: board.predefined,
        number_of_columns: board.number_of_columns,
        images: board.images.map do |image|
          {
            id: image.id,
            label: image.label,
            image_prompt: image.image_prompt,
            bg_color: image.bg_class,
            text_color: image.text_color,
            next_words: image.next_words,
            display_doc: image.display_image,
            src: image.display_image ? image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
            audio: image.audio_files.first&.url,
          }
        end,
      }
    end
    render json: @predictive_boards
  end

  def first_predictive_board
    @board = Board.predictive_default
    if @board
      puts "Predictive board found"
    else
      puts "No predictive board found"
      @board = Board.create_predictive_default
      puts "Predictive board created"
    end
    @board_with_images = @board.images.map do |image|
      {
        id: image.id,
        label: image.label,
        bg_color: image.bg_class,
        next_words: image.next_words,
        src: image.display_image(current_user)&.url || "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
        audio: image.audio_files.first&.url,
      }
    end
    render json: @board_with_images
  end

  def predictive_images
    @image = Image.find(params[:id])
    @next_images = @image.next_images.map do |ni|
      {
        id: ni.id,
        label: ni.label,
        bg_color: ni.bg_color,
        src: ni.display_image(current_user)&.url || "https://via.placeholder.com/300x300.png?text=#{ni.label_param}",
        audio: ni.audio_files.first&.url,
      }
    end
    render json: @next_images
  end

  # GET /boards/1 or /boards/1.json
  def show
    board = Board.includes(board_images: { image: :docs }).find(params[:id])
    @board_with_images = board.api_view_with_images
    user_permissions = {
      can_edit: (board.user == current_user || current_user.admin?),
      can_delete: (board.user == current_user || current_user.admin?),
    }
    render json: @board_with_images.merge(user_permissions)
  end

  def remaining_images
    # board = current_user.boards.includes(board_images: { image: :docs }).find(params[:id])
    puts "params: #{params.inspect}"
    puts "current_user: #{current_user.inspect}"
    board = Board.find(params[:id])
    current_page = params[:page] || 1
    puts "board: #{board.inspect}"
    if params[:query].present? && params[:query] != "null"
      @query = params[:query]
      @images = Image.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page(current_page)
    else
      @images = Image.all.order(label: :asc).page(current_page).page(current_page)
    end
    @images = @images.excluding(board.images)
    @remaining_images = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        display_doc: image.display_image,
        src: image.display_image ? image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
        audio: image.audio_files.first&.url,
      }
    end

    render json: @remaining_images
  end

  # POST /boards or /boards.json
  def create
    puts "API::BoardsController#create: #{board_params.inspect}"
    @board = Board.new(board_params)
    @board.user = current_user
    @board.parent_id = user_signed_in? ? current_user.id : params[:parent_id]
    @board.parent_type = params[:parent_type] || "User"

    respond_to do |format|
      if @board.save
        format.json { render json: @board, status: :created }
        format.turbo_stream
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    @board = Board.find(params[:id])
    @board.number_of_columns = board_params["number_of_columns"].to_i
    puts "handleSubmit: #{board_params} \n\n- params: #{params}"
    respond_to do |format|
      if @board.update(board_params)
        format.json { render json: @board.api_view_with_images, status: :ok }
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  def add_image
    puts "API:::BoardsController#create board_params: #{board_params} - params: #{params}"

    puts "\nAPI::BoardsController#create image_params: #{image_params} \n\n"
    @board = Board.find(params[:id])
    @found_image = Image.find_by(label: image_params[:label], user_id: current_user.id, private: true)
    @found_image ||= Image.find_by(label: image_params[:label])
    if @found_image
      @image = @found_image
      img_saved = true
    else
      @image = Image.new
      @image.user = current_user
      @image.private = true
      @image.label = image_params[:label]
      img_saved = @image.save!
    end

    if (image_params[:docs].present?)
      doc = @image.docs.new(image_params[:docs])
      doc.user = current_user
      doc.processed = true
      doc.save
    end
    if img_saved
      @board.add_image(@image.id) if @board

      @board_with_images = @board.api_view_with_images
      render json: @board_with_images
    else
      render json: img_saved.errors, status: :unprocessable_entity
    end
  end

  def associate_image
    image = Image.find(params[:image_id])
    if @board.images.include?(image)
      render json: { error: "Image already associated with board" }, status: :unprocessable_entity
      return
    end
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_entity
      return
    end
    new_board_image = @board.board_images.new(image_id: image.id)
    if new_board_image.save
      @board.reload
    else
      render json: { error: "Error adding image to board: #{new_board_image.errors.full_messages.join(", ")}" }, status: :unprocessable_entity
      return
    end

    render json: { board: @board, new_board_image: new_board_image }
  end

  def remove_image
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_entity
      return
    end
    @image = Image.find(params[:image_id])
    @board.images.delete(@image)
    @board.reload
    render json: @board, status: :ok
  end

  # # DELETE /boards/1 or /boards/1.json
  def destroy
    @board.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  # def clone
  #   @board = Board.includes(:images).find(params[:id])
  #   @new_board = Board.new
  #   @new_board.description = @board.description
  #   @new_board.user = current_user
  #   @new_board.parent_id = current_user.id
  #   @new_board.parent_type = "User"
  #   @new_board.predefined = false
  #   @new_board.name = "Copy of " + @board.name
  #   @board.images.each do |image|
  #     @new_board.add_image(image.id)
  #   end
  #   @new_board.save!
  #   redirect_to board_url(@new_board), notice: "Board was successfully cloned."
  # end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    @board = Board.includes(board_images: { image: :docs }).find(params[:id])
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:board).permit(:user_id, :name, :parent_id, :parent_type, :description, :number_of_columns, :predefined, :voice, :id)
  end
end
