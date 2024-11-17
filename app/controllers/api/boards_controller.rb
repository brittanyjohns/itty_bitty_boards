class API::BoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json

  # before_action :authenticate_user!
  skip_before_action :authenticate_token!, only: %i[ predictive_index first_predictive_board predictive_image_board ]

  before_action :set_board, only: %i[ associate_image remove_image destroy associate_images ]
  # layout "fullscreen", only: [:fullscreen]
  # layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @boards = Board.search_by_name(params[:query]).order(name: :asc).page params[:page]
        @predefined_boards = Board.predefined.search_by_name(params[:query]).order(name: :asc).page params[:page]
        render json: { boards: @boards, predefined_boards: @predefined_boards }
        return
      elsif params[:boards_only].present?
        @boards = current_user.boards.user_made_with_scenarios.order(name: :asc)
        @predefined_boards = Board.predefined.user_made_with_scenarios.order(name: :asc)
      else
        @boards = boards_for_user.user_made_with_scenarios.order(name: :asc)
        @predefined_boards = Board.predefined.user_made_with_scenarios.order(name: :asc)
      end

      # if current_user.admin?
      #   @boards = Board.all.order(name: :asc)
      # end

      @categories = @boards.map(&:category).uniq.compact
      @predictive_boards = current_user.boards.predictive.order(name: :asc)
      # @boards = current_user.boards.all.order(name: :asc)

      render json: { boards: @boards, predefined_boards: @predefined_boards, categories: @categories, all_categories: Board.categories, predictive_boards: @predictive_boards }
    end
  end

  def preset
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @predefined_boards = Board.predefined.search_by_name(params[:query]).order(name: :asc).page params[:page]
      elsif params[:filter].present?
        filter = params[:filter]
        unless Board::SAFE_FILTERS.include?(filter)
          render json: { error: "Invalid filter" }, status: :unprocessable_entity
          return
        end

        result = Board.predefined.send(filter)
        if result.is_a?(ActiveRecord::Relation)
          @predefined_boards = result.order(name: :asc).page params[:page]
        else
          @predefined_boards = result
        end
        # @predefined_boards = Board.predefined.where(category: params[:filter]).order(name: :asc).page params[:page]
      else
        @predefined_boards = Board.predefined.order(name: :asc)
      end
      @categories = @predefined_boards.map(&:category).uniq.compact
      @welcome_boards = Board.welcome
      render json: { predefined_boards: @predefined_boards, categories: @categories, all_categories: Board.categories, welcome_boards: @welcome_boards.map(&:api_view_with_images) }
    end
  end

  def categories
    @categories = Board.categories
    render json: @categories
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.order(name: :asc)
    @boards = current_user.boards.user_made_with_scenarios.order(name: :asc)

    render json: { boards: @boards }
  end

  def predictive_index
    @boards = Board.with_artifacts.predictive
    @predictive_boards = @boards.map do |board|
      {
        id: board.id,
        name: board.name,
        description: board.description,
        can_edit: (board.user == current_user || current_user.admin?),
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
    @user_type = params[:user_type] || "user"
    puts "User type: #{@user_type}"

    if @user_type == "user"
      viewing_user = current_user
    elsif @user_type == "child"
      puts "Child user - finding child user: current_user: #{current_child.inspect}"
      viewing_user = current_child.user
    end

    id_from_env = ENV["PREDICTIVE_DEFAULT_ID"]

    puts "viewing_user&.settings: #{viewing_user&.settings}"

    user_predictive_board_id = viewing_user&.settings["predictive_default_id"] ? viewing_user.settings["predictive_default_id"].to_i : nil
    puts "User predictive board ID: #{user_predictive_board_id}"
    custom_board = nil
    if user_predictive_board_id && Board.exists?(user_predictive_board_id) && user_predictive_board_id != id_from_env.to_i
      @board = Board.find_by(id: user_predictive_board_id)
      custom_board = true
    else
      @board = Board.find_by(id: id_from_env)
      custom_board = false
    end

    if @board.nil?
      puts "Predictive board not found"
      @board = Board.find_by(name: "Predictive Default", user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource")
      custom_board = false
    end

    unless custom_board
      puts "Predictive board not custom - setting user predictive default ID"
      CreateCustomPredictiveDefaultJob.perform_async(viewing_user.id)
    end

    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("First Predictive Board") do
        @loaded_board = Board.with_artifacts.find(@board.id)
        @board_with_images = @loaded_board.api_view_with_predictive_images(viewing_user)
      end
      render json: @board_with_images
    end
    # render json: @board_with_images
  end

  def predictive_image_board
    @board = Board.find(params[:id])
    # expires_in 8.hours, public: true # Cache control header

    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("Predictive Image Board") do
        @loaded_board = Board.with_artifacts.find(@board.id)
        @board_with_images = @loaded_board.api_view_with_predictive_images(current_user)
      end
      render json: @board_with_images
    end

    # render json: @board.api_view_with_predictive_images(current_user)
  end

  def show
    # board = Board.with_artifacts.find(params[:id])
    set_board
    user_permissions = {
      can_edit: (@board.user == current_user || current_user.admin?),
      can_delete: (@board.user == current_user || current_user.admin?),
    }
    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("Show Board") do
        # @loaded_board = Board.with_artifacts.find(@board.id)
        @board_with_images = @board.api_view_with_predictive_images(current_user)
      end
      render json: @board_with_images.merge(user_permissions)
    end
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
    word_list = params[:word_list]&.compact || board_params[:word_list]&.compact

    @board.find_or_create_images_from_word_list(word_list) if word_list.present?
    @board.reset_layouts

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
    @board.category = board_params["category"]
    if !params["word_list"].blank?
      word_list = params[:word_list]&.compact || board_params[:word_list]&.compact
      @board.find_or_create_images_from_word_list(word_list) if word_list.present?
    end

    if params["image_ids_to_remove"].present?
      image_ids_to_remove = params["image_ids_to_remove"]
      puts "Image IDs to remove: #{image_ids_to_remove}"
      image_ids_to_remove.each do |image_id|
        image = Image.find(image_id)
        @board.remove_image(image&.id) if @board && image
      end
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
    name_to_send = params[:name] || @board.name
    result = @board.get_words(name_to_send, num_of_words, @board.words)
    additional_words = result
    @board.find_or_create_images_from_word_list(additional_words)
    render json: @board.api_view_with_images(current_user)
  end

  def additional_words
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    board_words = @board.images.map(&:label).uniq
    name_to_send = params[:name] || @board.name
    additional_words = @board.get_words(name_to_send, num_of_words, board_words)
    render json: additional_words
  end

  def words
    additional_words = Board.new.get_word_suggestions(params[:name], params[:num_of_words])

    render json: additional_words
  end

  def format_with_ai
    set_board
    screen_size = params[:screen_size] || "lg"
    puts "Formatting board with AI for screen size: #{screen_size}"
    FormatBoardWithAiJob.perform_async(@board.id, screen_size)
    # @board.format_board_with_ai(screen_size)
    @board.update(status: "formatting")
    puts "Board formatted with AI"
    render json: @board.api_view_with_images(current_user)
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

  # def create_from_next_words
  #   @board = Board.new(board_params)
  #   @board.user = current_user
  #   @board.parent_id = user_signed_in? ? current_user.id : params[:parent_id]
  #   @board.parent_type = params[:parent_type] || "User"
  #   @board.save!
  #   @board.create_images_from_next_words(params[:next_words])
  #   render json: @board.api_view_with_images(current_user)
  # end

  def associate_image
    @image = Image.find(params[:image_id])
    screen_size = params[:screen_size] || "lg"
    if @board.images.include?(@image)
      render json: { error: "Image already associated with board" }, status: :unprocessable_entity
      return
    end
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_entity
      return
    end

    new_board_image = @board.add_image(@image.id) if @board
    notice = "Image added to board"
    if new_board_image
      render json: @board.api_view_with_images(current_user), notice: notice
    else
      render json: { error: "Error adding image to board" }, status: :unprocessable_entity
    end

    # new_board_image = @board.board_images.new(image_id: image.id, position: @board.board_images.count)
    # new_board_image.layout = new_board_image.initial_layout
    # if new_board_image.save
    #   @board.board_images.reset
    #   render json: { board: @board, new_board_image: new_board_image, label: image.label }
    # else
    #   render json: { error: "Error adding image to board: #{new_board_image.errors.full_messages.join(", ")}" }, status: :unprocessable_entity
    # end
  end

  def associate_images
    images = Image.where(id: params[:image_ids])
    screen_size = params[:screen_size] || "lg"
    if @board.images.include?(images)
      render json: { error: "Image already associated with board" }, status: :unprocessable_entity
      return
    end

    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_entity
      return
    end

    new_board_images = []
    images.each do |image|
      if @board.images.include?(image)
        next
      end
      new_board_image = @board.board_images.new(image_id: image.id, position: @board.board_images.count)
      new_board_image.layout = new_board_image.initial_layout
      new_board_image.save
      new_board_images << new_board_image
    end
    # @board.reset_multiple_images_layout_all_screen_sizes(new_board_images)
    # @board.calculate_layout_for_multiple_images(new_board_images, "lg")
    @board.reload
    render json: { board: @board, new_board_images: new_board_images }
  end

  def remove_image
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_entity
      return
    end
    @image = Image.find_by(id: params[:image_id])
    @board.remove_image(@image&.id) if @board && @image
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
    # ActiveRecord::Base.logger.silence do
    @board = Board.with_artifacts.find(params[:id])
    # end
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
                                  :display_image_url, :category, :word_list, :image_ids_to_remove)
  end
end
