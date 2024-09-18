class API::BoardsController < API::ApplicationController
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

        # @boards = boards_for_user.user_made_with_scenarios.where("name ILIKE ?", "%#{params[:query]}%").order(created_at: :desc)
        # @predefined_boards = Board.predefined.user_made_with_scenarios.where("name ILIKE ?", "%#{params[:query]}%").order(created_at: :desc)
        @boards = Board.search_by_name(params[:query]).order(created_at: :desc).page params[:page]
        @predefined_boards = Board.predefined.search_by_name(params[:query]).order(created_at: :desc).page params[:page]
        render json: { boards: @boards, predefined_boards: @predefined_boards }
        return
      elsif params[:boards_only].present?
        # @boards = boards_for_user.user_made_with_scenarios.order(created_at: :desc)
        @boards = current_user.boards.user_made_with_scenarios.order(created_at: :desc)
        @predefined_boards = Board.predefined.user_made_with_scenarios.order(created_at: :desc)
      else
        @boards = boards_for_user.user_made_with_scenarios.order(created_at: :desc)
        @predefined_boards = Board.predefined.user_made_with_scenarios.order(created_at: :desc)
      end

      if current_user.admin?
        @boards = Board.all.order(created_at: :desc)
      end

      # render json: { boards: @boards.map { |b| b.api_view(current_user) },
      #                predefined_boards: @predefined_boards }
      render json: { boards: @boards, predefined_boards: @predefined_boards }
    end
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.order(created_at: :desc)
    @boards = boards_for_user.user_made_with_scenarios.order(created_at: :desc)

    render json: { boards: @boards }
  end

  def predictive_index
    @boards = Board.with_artifacts.predictive
    @predictive_boards = @boards.map do |board|
      {
        id: board.id,
        name: board.name,
        description: board.description,
        parent_type: board.parent_type,
        predefined: board.predefined,
        number_of_columns: board.number_of_columns,
        images: board.board_images.map do |board_image|
          {
            id: board_image.image.id,
            label: board_image.image.label,
            image_prompt: board_image.image.image_prompt,
            bg_color: board_image.image.bg_class,
            text_color: board_image.image.text_color,
            next_words: board_image.next_words,
            position: board_image.position,
            src: board_image.image.display_image_url(current_user),
            audio: board_image.audio_url,
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

    @board_with_images = @board.api_view_with_images(current_user)
    render json: @board_with_images
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
    # board = Board.with_artifacts.find(params[:id])
    set_board
    @board_with_images = @board.api_view_with_images(current_user)
    user_permissions = {
      can_edit: (@board.user == current_user || current_user.admin?),
      can_delete: (@board.user == current_user || current_user.admin?),
    }
    render json: @board_with_images.merge(user_permissions)
  end

  def save_layout
    set_board
    # board = Board.with_artifacts.find(params[:id])
    layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash

    screen_size = params[:screen_size] || "lg"
    if params[:small_screen_columns].present? || params[:medium_screen_columns].present? || params[:large_screen_columns].present?
      @board.small_screen_columns = params[:small_screen_columns].to_i if params[:small_screen_columns].present?
      @board.medium_screen_columns = params[:medium_screen_columns].to_i if params[:medium_screen_columns].present?
      @board.large_screen_columns = params[:large_screen_columns].to_i if params[:large_screen_columns].present?
    end
    margin_x = params[:xMargin].to_i
    margin_y = params[:yMargin].to_i
    if margin_x.present? && margin_y.present?
      @board.margin_settings[screen_size] = { x: margin_x, y: margin_y }
    end
    if params[:settings].present?
      @board.settings[screen_size] = params[:settings]
    end
    @board.save!
    begin
      @board.update_grid_layout(layout, screen_size)
    rescue => e
      Rails.logger.error "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
    end
    @board.reload

    render json: @board.api_view_with_images(current_user)
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
    @images = @images.excluding(@board.images)
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

    @board.reset_layouts
    @board.save!
    render json: @board.api_view_with_images(current_user)
  end

  # POST /boards or /boards.json
  def create
    @board = Board.new(board_params)
    @board.user = current_user
    @board.parent_id = user_signed_in? ? current_user.id : params[:parent_id]
    @board.parent_type = params[:parent_type] || "User"
    @board.predefined = false
    @board.small_screen_columns = board_params["small_screen_columns"].to_i
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @board.large_screen_columns = board_params["large_screen_columns"].to_i
    @board.voice = params["voice"]

    respond_to do |format|
      if @board.save
        word_list = params[:word_list]&.compact || board_params[:word_list]&.compact

        @board.create_images_from_word_list(word_list) if word_list.present?
        format.json { render json: @board, status: :created }
        format.turbo_stream
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    set_board
    @board.number_of_columns = board_params["number_of_columns"].to_i
    @board.small_screen_columns = board_params["small_screen_columns"].to_i
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @board.large_screen_columns = board_params["large_screen_columns"].to_i
    @board.voice = board_params["voice"]
    @board.name = board_params["name"]
    @board.description = board_params["description"]
    @board.display_image_url = board_params["display_image_url"]
    @board.predefined = board_params["predefined"]
    if params["word_list"].present?
      word_list = params[:word_list]&.compact || board_params[:word_list]&.compact
      @board.create_images_from_word_list(word_list)
    end

    respond_to do |format|
      if @board.save
        format.json { render json: @board.api_view_with_images(current_user), status: :ok }
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  def create_additional_images
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    result = @board.get_words(num_of_words)
    puts "Result: #{result}"
    additional_words = result["additional_words"]
    @board.create_images_from_word_list(additional_words)
    render json: @board.api_view_with_images(current_user)
  end

  def additional_words
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    board_words = @board.images.map(&:label).uniq
    additional_words = @board.get_words(num_of_words)
    render json: additional_words
  end

  def words
    additional_words = Board.new.get_word_suggestions(params[:name], params[:num_of_words])

    render json: additional_words
  end

  def add_image
    set_board
    # @board = Board.with_artifacts.find(params[:id])
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

      screen_size = params[:screen_size] || "lg"
      # @board.calculate_grid_layout_for_screen_size(screen_size)
      @board.reload
      @board_with_images = @board.api_view_with_images(current_user)

      render json: @board_with_images
    else
      render json: img_saved.errors, status: :unprocessable_entity
    end
  end

  def create_from_next_words
    @board = Board.new(board_params)
    @board.user = current_user
    @board.parent_id = user_signed_in? ? current_user.id : params[:parent_id]
    @board.parent_type = params[:parent_type] || "User"
    @board.save!
    @board.create_images_from_next_words(params[:next_words])
    render json: @board.api_view_with_images(current_user)
  end

  def associate_image
    image = Image.find(params[:image_id])
    screen_size = params[:screen_size] || "lg"
    if @board.images.include?(image)
      render json: { error: "Image already associated with board" }, status: :unprocessable_entity
      return
    end
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_entity
      return
    end

    new_board_image = @board.board_images.new(image_id: image.id, position: @board.board_images.count)
    new_board_image.layout = new_board_image.initial_layout
    if new_board_image.save
      @board.board_images.reset
      render json: { board: @board, new_board_image: new_board_image, label: image.label }
    else
      render json: { error: "Error adding image to board: #{new_board_image.errors.full_messages.join(", ")}" }, status: :unprocessable_entity
    end
  end

  def remove_image
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_entity
      return
    end
    @image = Image.find(params[:image_id])
    @board.remove_image(@image)
    # @board.images.delete(@image)
    @board.reload
    render json: { board: @board, status: :ok }
  end

  # # DELETE /boards/1 or /boards/1.json
  def destroy
    @board.destroy!

    puts "Board destroyed"

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  def add_to_team
    @team = Team.find(params[:team_id])
    @board = Board.find(params[:id])
    @team.boards << @board
    render json: @team.show_api_view
  end

  def clone
    set_board
    new_name = "Copy of " + @board.name
    @new_board = @board.clone_with_images(current_user.id, new_name)
    render json: @new_board.api_view_with_images(current_user)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    ActiveRecord::Base.logger.silence do
      @board = Board.with_artifacts.find(params[:id])
    end
  end

  def boards_for_user
    current_user.boards.with_artifacts
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:board).permit(:user_id,
                                  :name,
                                  :parent_id,
                                  :parent_type,
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
