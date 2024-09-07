class API::DynamicBoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json

  # before_action :authenticate_user!
  skip_before_action :authenticate_token!, only: %i[ predictive_index first_predictive_board predictive_images ]

  before_action :set_board, only: %i[ associate_image remove_image destroy ]
  # layout "fullscreen", only: [:fullscreen]
  # layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @query = params[:query]
        @dynamic_boards = boards_for_user.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
      elsif params[:boards_only].present?
        # @dynamic_boards = boards_for_user.order(created_at: :desc)
        @dynamic_boards = current_user.dynamic_boards.order(created_at: :desc)
      else
        @dynamic_boards = boards_for_user.order(created_at: :desc)
      end

      if current_user.admin?
        @dynamic_boards = DynamicBoard.all.order(name: :desc)
      end

      # render json: { boards: @dynamic_boards.map { |b| b.api_view(current_user) },
      #                predefined_boards: @predefined_boards }
      render json: { dynamic: @dynamic_boards.map { |b| b.api_view_with_images(current_user) } }
    end
  end

  def user_boards
    # @dynamic_boards = boards_for_user_and_menus.order(created_at: :desc)
    @dynamic_boards = boards_for_user.order(created_at: :desc)

    render json: { boards: @dynamic_boards }
  end

  def predictive_index
    @dynamic_boards = DynamicBoard.with_artifacts.predictive
    @predictive_boards = @dynamic_boards.map do |board|
      {
        id: board.id,
        name: board.name,
        description: board.description,
        parent_type: board.parent_type,
        predefined: board.predefined,
        number_of_columns: board.number_of_columns,
        images: board.dynamic_board_images.map do |board_image|
          {
            id: board_image.image.id,
            label: board_image.image.label,
            image_prompt: board_image.image.image_prompt,
            bg_color: board_image.image.bg_class,
            text_color: board_image.image.text_color,
            next_words: board_image.next_words,
            # position: board_image.position,
            src: board_image.image.display_image_url(current_user),
            audio: board_image.audio_url,
          }
        end,
      }
    end
    render json: @predictive_boards
  end

  def first_predictive_board
    @dynamic_board = DynamicBoard.predictive_default
    if @dynamic_board
      puts "Predictive board found"
    else
      puts "No predictive board found"
      @dynamic_board = DynamicBoard.create_predictive_default
      puts "Predictive board created"
    end

    @dynamic_board_with_images = @dynamic_board.api_view_with_images(current_user)
    render json: @dynamic_board_with_images
  end

  def predictive_images
    @image = Image.with_artifacts.find(params[:id])
    @next_images = @image.next_images.map do |ni|
      {
        id: ni.id,
        label: ni.label,
        bg_color: ni.bg_class,
        src: ni.display_image_url(current_user),
        audio: ni.default_audio_url,
      }
    end
    render json: @next_images
  end

  def show
    # board = DynamicBoard.with_artifacts.find(params[:id])
    set_board
    @dynamic_board_with_images = @dynamic_board.api_view_with_images(current_user)
    user_permissions = {
      can_edit: (@dynamic_board.user == current_user || current_user.admin?),
      can_delete: (@dynamic_board.user == current_user || current_user.admin?),
    }
    render json: @dynamic_board_with_images.merge(user_permissions)
  end

  def save_layout
    set_board
    # board = DynamicBoard.with_artifacts.find(params[:id])
    layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash

    screen_size = params[:screen_size] || "lg"
    if params[:small_screen_columns].present? || params[:medium_screen_columns].present? || params[:large_screen_columns].present?
      @dynamic_board.small_screen_columns = params[:small_screen_columns].to_i if params[:small_screen_columns].present?
      @dynamic_board.medium_screen_columns = params[:medium_screen_columns].to_i if params[:medium_screen_columns].present?
      @dynamic_board.large_screen_columns = params[:large_screen_columns].to_i if params[:large_screen_columns].present?
      @dynamic_board.save!
    end
    @dynamic_board.reload
    begin
      @dynamic_board.update_grid_layout(layout, screen_size)
    rescue => e
      Rails.logger.error "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
      puts "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
    end
    @dynamic_board.reload

    render json: @dynamic_board.api_view_with_images(current_user)
  end

  def remaining_images
    set_board
    current_page = params[:page] || 1
    if params[:query].present? && params[:query] != "null"
      @query = params[:query]
      @images = Image.non_menu_images.with_artifacts.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page(current_page)
    else
      @images = Image.non_menu_images.with_artifacts.all.order(label: :asc).page(current_page).page(current_page)
    end
    @images = @images.excluding(@dynamic_board.images)
    @remaining_images = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        bg_color: image.bg_class,
        text_color: image.text_color,
        src: image.display_image_url(current_user),
      # audio: image.default_audio_url,
      }
    end

    render json: @remaining_images
  end

  def rearrange_images
    set_board

    @dynamic_board.reset_layouts
    @dynamic_board.save!
    render json: @dynamic_board.api_view_with_images(current_user)
  end

  # POST /boards or /boards.json
  def create
    @dynamic_board = DynamicBoard.new(board_params)
    @dynamic_board.user = current_user
    @dynamic_board.parent_type = params[:parent_type] || "User"
    @dynamic_board.predefined = false
    @dynamic_board.small_screen_columns = board_params["small_screen_columns"].to_i
    @dynamic_board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @dynamic_board.large_screen_columns = board_params["large_screen_columns"].to_i
    @dynamic_board.voice = params["voice"]

    respond_to do |format|
      if @dynamic_board.save
        format.json { render json: @dynamic_board, status: :created }
        format.turbo_stream
      else
        format.json { render json: @dynamic_board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    set_board
    @dynamic_board.number_of_columns = board_params["number_of_columns"].to_i
    @dynamic_board.small_screen_columns = board_params["small_screen_columns"].to_i
    @dynamic_board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @dynamic_board.large_screen_columns = board_params["large_screen_columns"].to_i
    @dynamic_board.voice = params["voice"]
    @dynamic_board.name = params["name"]
    @dynamic_board.description = params["description"]
    @dynamic_board.display_image_url = params["display_image_url"]
    @dynamic_board.predefined = params["predefined"]
    puts "API::DynamicBoardsController#update: #{params.inspect}"
    puts @dynamic_board.voice ? "Voice: #{@dynamic_board.voice}" : "No voice"
    respond_to do |format|
      if @dynamic_board.save
        format.json { render json: @dynamic_board.api_view_with_images(current_user), status: :ok }
      else
        format.json { render json: @dynamic_board.errors, status: :unprocessable_entity }
      end
    end
  end

  def add_image
    set_board
    # @dynamic_board = DynamicBoard.with_artifacts.find(params[:id])
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
      @dynamic_board.add_image(@image.id) if @dynamic_board

      screen_size = params[:screen_size] || "lg"
      # @dynamic_board.calculate_grid_layout_for_screen_size(screen_size)
      @dynamic_board.reload
      @dynamic_board_with_images = @dynamic_board.api_view_with_images(current_user)

      render json: @dynamic_board_with_images
    else
      render json: img_saved.errors, status: :unprocessable_entity
    end
  end

  def create_from_next_words
    @dynamic_board = DynamicBoard.new(board_params)
    @dynamic_board.user = current_user
    @dynamic_board.parent_type = params[:parent_type] || "User"
    @dynamic_board.save!
    @dynamic_board.create_images_from_next_words(params[:next_words])
    render json: @dynamic_board.api_view_with_images(current_user)
  end

  def associate_image
    image = Image.find(params[:image_id])
    screen_size = params[:screen_size] || "lg"
    if @dynamic_board.images.include?(image)
      render json: { error: "Image already associated with board" }, status: :unprocessable_entity
      return
    end
    if @dynamic_board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_entity
      return
    end

    new_board_image = @dynamic_board.dynamic_board_images.new(image_id: image.id, position: @dynamic_board.dynamic_board_images.count)
    new_board_image.layout = new_board_image.initial_layout
    if new_board_image.save
      @dynamic_board.dynamic_board_images.reset
      render json: { board: @dynamic_board, new_board_image: new_board_image, label: image.label }
    else
      render json: { error: "Error adding image to board: #{new_board_image.errors.full_messages.join(", ")}" }, status: :unprocessable_entity
    end
  end

  def remove_image
    if @dynamic_board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_entity
      return
    end
    @image = Image.find(params[:image_id])
    @dynamic_board.remove_image(@image)
    # @dynamic_board.images.delete(@image)
    @dynamic_board.reload
    render json: { board: @dynamic_board, status: :ok }
  end

  # # DELETE /boards/1 or /boards/1.json
  def destroy
    @dynamic_board.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  def add_to_team
    @team = Team.find(params[:team_id])
    @dynamic_board = DynamicBoard.find(params[:id])
    @team.dynamic_boards << @dynamic_board
    render json: @team.show_api_view
  end

  def clone
    set_board
    new_name = "Copy of " + @dynamic_board.name
    @new_board = @dynamic_board.clone_with_images(current_user.id, new_name)
    render json: @new_board.api_view_with_images(current_user)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    ActiveRecord::Base.logger.silence do
      @dynamic_board = DynamicBoard.with_artifacts.find(params[:id])
    end
  end

  def boards_for_user
    current_user.dynamic_boards.with_artifacts
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:board).permit(:user_id,
                                  :name,
                                  :description,
                                  :predefined,
                                  :number_of_columns,
                                  :voice,
                                  :small_screen_columns,
                                  :medium_screen_columns,
                                  :large_screen_columns,
                                  :next_words,
                                  :images,
                                  :layout,
                                  :image_ids,
                                  :image_id,
                                  :query,
                                  :page,
                                  :display_image_url)
  end
end
