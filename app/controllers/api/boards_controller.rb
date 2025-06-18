class API::BoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  # respond_to :json

  # before_action :authenticate_user!
  skip_before_action :authenticate_token!, only: %i[ index predictive_image_board preset show public_boards public_menu_boards common_boards ]

  before_action :set_board, only: %i[ associate_image remove_image destroy associate_images ]
  before_action :check_board_view_edit_permissions, only: %i[update destroy]
  before_action :check_board_create_permissions, only: %i[ create clone ]
  # layout "fullscreen", only: [:fullscreen]
  # layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    unless current_user
      @static_preset_boards = Board.static.predefined.order(name: :asc).page params[:page]
      @dynamic_preset_boards = Board.dynamic.predefined.order(name: :asc).page params[:page]
      @predictive_preset_boards = Board.predictive.predefined.order(name: :asc).page params[:page]
      @category_preset_boards = Board.categories.predefined.order(name: :asc).page params[:page]
      render json: { static_preset_boards: @static_preset_boards.map(&:api_view),
                     dynamic_preset_boards: @dynamic_preset_boards.map(&:api_view),
                     predictive_preset_boards: @predictive_preset_boards.map(&:api_view),
                     category_preset_boards: @category_preset_boards.map(&:api_view) }
      return
    end
    if params[:query].present?
      @search_results = Board.for_user(current_user).searchable.search_by_name(params[:query]).order(name: :asc).page params[:page]
      render json: { search_results: @search_results } and return
    end
    @predefined_boards = Board.predefined
    @user_boards = current_user.boards.where(predefined: false)
    @predictive_boards = @user_boards.predictive.order(name: :asc).page params[:page]
    @dynamic_boards = @user_boards.dynamic.order(name: :asc).page params[:page]
    @category_boards = @user_boards.categories.order(name: :asc).page params[:page]
    @static_boards = @user_boards.static.order(name: :asc).page params[:page]
    @static_preset_boards = @predefined_boards.static.order(name: :asc).page params[:page]
    @dynamic_preset_boards = @predefined_boards.dynamic.order(name: :asc).page params[:page]
    @predictive_preset_boards = @predefined_boards.predictive.order(name: :asc).page params[:page]
    @category_preset_boards = @predefined_boards.categories.order(name: :asc).page params[:page]
    @newly_created_boards = @user_boards.where("created_at >= ?", 1.week.ago).order(created_at: :desc).limit(10)
    @recently_used_boards = current_user.recently_used_boards

    render json: { category_preset_boards: @category_preset_boards.map(&:api_view),
                   static_preset_boards: @static_preset_boards.map(&:api_view),
                   dynamic_preset_boards: @dynamic_preset_boards.map(&:api_view),
                   predictive_preset_boards: @predictive_preset_boards.map(&:api_view),
                   predictive_boards: @predictive_boards.map(&:api_view),
                   dynamic_boards: @dynamic_boards.map(&:api_view),
                   category_boards: @category_boards.map(&:api_view),
                   newly_created_boards: @newly_created_boards.map(&:api_view),
                   recently_used_boards: @recently_used_boards.map(&:api_view),
                   boards: @static_boards.map(&:api_view) }
  end

  def public_boards
    @public_boards = Board.public_boards
    render json: { public_boards: @public_boards.map(&:api_view) }
  end

  def common_boards
    @common_boards = Board.common_boards
    render json: { common_boards: @common_boards.map(&:api_view) }
  end

  def public_menu_boards
    @public_menu_boards = Board.public_menu_boards.order(name: :asc).page params[:page]
    render json: { public_menu_boards: @public_menu_boards.map(&:api_view) }
  end

  def preset
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
    # render json: { predefined_boards: @predefined_boards, categories: @categories, all_categories: Board.board_categories }
    render json: { predefined_boards: @predefined_boards.map(&:api_view) }
  end

  def categories
    @categories = Board.board_categories
    render json: @categories
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.order(name: :asc)
    @boards = current_user.boards.user_made_with_scenarios.order(name: :asc)

    render json: { boards: @boards, dynamic_boards: current_user.boards.dynamic.order(name: :asc) }
  end

  def predictive_image_board
    @board = Board.with_artifacts.find_by(id: params[:id])
    if @board.nil?
      @board = Board.predictive_default(current_user)
    end
    # expires_in 8.hours, public: true # Cache control header
    @board_group = BoardGroup.find_by(id: params[:board_group_id]) if params[:board_group_id].present?

    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("Predictive Image Board") do
        # @loaded_board = Board.with_artifacts.find(@board.id)
        @board_with_images = @board.api_view_with_predictive_images(current_user)
      end
      @board_with_images[:root_board_id] = @board_group&.root_board_id
      render json: @board_with_images
    end

    # render json: @board.api_view_with_predictive_images(current_user)
  end

  def show
    set_board

    # if stale?(etag: @board, last_modified: @board.updated_at)
    #   RailsPerformance.measure("Show Board") do
    # @loaded_board = Board.with_artifacts.find(@board.id)
    @board_with_images = @board.api_view_with_predictive_images(current_user, nil, true)
    # end
    render json: @board_with_images
    # end
  end

  def initial_predictive_board
    @board = Board.predictive_default
    Rails.logger.info "Initial predictive board ID: #{@board&.id}"
    if @board.nil?
      @board = Board.with_artifacts.find_by(user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource")
      current_user.settings["dynamic_board_id"] = nil
      current_user.save!
    end
    render json: @board.api_view_with_images(current_user)
  end

  def save_layout
    set_board
    save_layout!

    @board.reload
    render json: @board.api_view_with_images(current_user)
  end

  def remaining_images
    set_board
    current_page = params[:page] || 1
    if params[:query].present? && params[:query] != "null"
      @query = params[:query]
      @images = Image.searchable.with_artifacts.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc)
    else
      @images = Image.searchable.with_artifacts.all.order(label: :asc)
    end

    if params[:scope]
      case params[:scope]
      when "predictive"
        @images = @images.category
      when "category"
        @images = @images.category
      when "static"
        @images = @images.static
      end
    end
    @images = @images.where(user_id: [current_user.id, User::DEFAULT_ADMIN_ID, nil]).distinct
    @images = @images.excluding(@board.images).page(current_page)

    if params[:scope] == "predictive"
      @images_with_display_doc = @images.map do |image|
        api_view = image.api_view(current_user)
        any_board_imgs = api_view[:any_board_imgs]
        if any_board_imgs.any?
          api_view
        else
          nil
        end
      end
    else
      @images_with_display_doc = @images.map(&:api_view)
    end

    @images_with_display_doc = @images_with_display_doc.compact

    return_data = {
      total_pages: @images.total_pages,
      page_size: @images.limit_value,
      data: @images_with_display_doc.sort { |a, b| a[:label] <=> b[:label] },
    }
    render json: return_data
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
    board_type = params[:board_type] || board_params[:board_type]
    settings = params[:settings] || board_params[:settings] || {}
    settings["board_type"] = board_type
    @board.board_type = board_type || "static"
    @board.assign_parent

    @board.predefined = false
    @board.small_screen_columns = board_params["small_screen_columns"].to_i
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @board.large_screen_columns = board_params["large_screen_columns"].to_i
    @board.voice = params["voice"] if params["voice"].present?
    @board.language = board_params["language"] if board_params["language"].present?

    word_list = params[:word_list]&.compact || board_params[:word_list]&.compact

    # matching_image = @board.matching_image
    # if board_type == "dynamic"
    #   predefined_resource = PredefinedResource.find_or_create_by(name: "Default", resource_type: "Board")
    #   @board.parent_id = predefined_resource.id
    #   @board.parent_type = "PredefinedResource"
    #   @board.board_type = "dynamic"
    # elsif board_type == "predictive"
    #   @board.parent_type = "Image"
    #   # matching_image = @board.user.images.find_or_create_by(label: @board.name, image_type: "predictive")
    #   @board.board_type = "predictive"
    #   matching_image ||= @board.create_matching_image
    #   if matching_image
    #     @board.parent_id = matching_image.id
    #     @board.image_parent_id = matching_image.id
    #     # matching_image.update(image_type: "predictive")
    #   end
    # elsif board_type == "category"
    #   @board.board_type = "category"
    #   @board.parent_type = "PredefinedResource"
    #   @board.parent_id = PredefinedResource.find_or_create_by(name: "Default", resource_type: "Category").id
    #   # matching_image = @board.user.images.find_or_create_by(label: @board.name, image_type: "category")
    #   matching_image ||= @board.create_matching_image
    #   if matching_image
    #     @board.image_parent_id = matching_image.id
    #   end
    # elsif board_type == "static"
    #   @board.parent_type = "User"
    #   @board.parent_id = @board_user.id
    #   @board.board_type = "static"
    # end
    @board.settings = settings

    @board.find_or_create_images_from_word_list(word_list) if word_list.present?
    @board.reset_layouts

    respond_to do |format|
      if @board.save
        format.json { render json: @board, status: :created }
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    set_board
    @board_user = @board.user
    if params["image_ids_to_remove"].present?
      image_ids_to_remove = params["image_ids_to_remove"]
      image_ids_to_remove.each do |image_id|
        image = Image.find(image_id)
        @board.remove_image(image&.id) if @board && image
      end
      render json: @board.api_view_with_images(current_user)
      return
    else
      @board.number_of_columns = board_params["number_of_columns"].to_i
      @board.small_screen_columns = board_params["small_screen_columns"].to_i
      @board.medium_screen_columns = board_params["medium_screen_columns"].to_i
      @board.large_screen_columns = board_params["large_screen_columns"].to_i
      @board.voice = board_params["voice"]
      @board.name = board_params["name"] unless board_params["name"].blank?
      @board.description = board_params["description"]
      @board.display_image_url = board_params["display_image_url"]
      @board.predefined = board_params["predefined"]
      @board.category = board_params["category"]
      @board.display_image_url = board_params["display_image_url"]
      @board.language = board_params["language"] if board_params["language"].present?
      @board.favorite = board_params["favorite"] if board_params["favorite"].present?
      @board.published = board_params["published"] if board_params["published"].present?

      board_type = params[:board_type] || board_params[:board_type]
      settings = params[:settings] || board_params[:settings] || {}
      settings["board_type"] = board_type
      matching_image = @board.matching_image
      if board_type == "dynamic"
        predefined_resource = PredefinedResource.find_or_create_by(name: "Default", resource_type: "Board")
        @board.parent_id = predefined_resource.id
        @board.parent_type = "PredefinedResource"
        @board.board_type = "dynamic"
      elsif board_type == "predictive"
        @board.parent_type = "Image"
        # matching_image = @board.user.images.find_or_create_by(label: @board.name, image_type: "predictive")
        @board.board_type = "predictive"
        matching_image ||= @board.create_matching_image
        if matching_image
          @board.parent_id = matching_image.id
          @board.image_parent_id = matching_image.id
          # matching_image.update(image_type: "predictive")
        end
      elsif board_type == "category"
        @board.board_type = "category"
        @board.parent_type = "PredefinedResource"
        @board.parent_id = PredefinedResource.find_or_create_by(name: "Default", resource_type: "Category").id
        # matching_image = @board.user.images.find_or_create_by(label: @board.name, image_type: "category")
        matching_image ||= @board.create_matching_image
        if matching_image
          @board.image_parent_id = matching_image.id
        end
      elsif board_type == "static"
        @board.parent_type = "User"
        @board.parent_id = @board_user.id
        @board.board_type = "static"
      end
      new_board_settings = @board.settings.merge(settings)
      @board.settings = new_board_settings
      word_list = params["word_list"] || []
      words_to_create = []
      current_word_list = @board.current_word_list
      word_list.each do |word|
        if word.is_a?(String) && word.present?
          unless current_word_list.include?(word)
            words_to_create << word
          end
        end
      end

      if !words_to_create.blank?
        @board.find_or_create_images_from_word_list(words_to_create)
      end

      respond_to do |format|
        if @board.save
          if params[:layout].present?
            layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash
            save_layout!
          end
          format.json { render json: @board.api_view_with_images(current_user), status: :ok }
        else
          format.json { render json: @board.errors, status: :unprocessable_entity }
        end
      end
    end
  end

  def update_preset_display_image
    set_board
    image_data = board_params[:preset_display_image]
    if image_data.blank?
      render json: { error: "No image data provided" }, status: :unprocessable_entity
      return
    end

    file_extension = board_params[:preset_display_image]
    file_extension = file_extension.content_type.split("/").last if file_extension
    attach_image_to_board(image_data, file_extension)
    render json: @board.api_view_with_images(current_user)
  end

  def download_obf
    set_board
    obf_board = @board.to_obf(current_user)
    send_data obf_board.to_json, filename: "board.obf", type: "application/json", disposition: "attachment"
  end

  def import_obf
    if params[:file].present?
      uploaded_file = params[:file]
      file_extension = File.extname(uploaded_file.original_filename)
      file_name = uploaded_file.original_filename

      if file_extension == ".obz"
        extracted_obz_data = OBF::OBZ.to_external(uploaded_file, {})
        @get_manifest_data = Board.extract_manifest(uploaded_file.path)
        parsed_manifest = JSON.parse(@get_manifest_data)

        @root_board_id_key = parsed_manifest["root"]
        paths = parsed_manifest["paths"]
        boards = paths["boards"]
        @root_board_id = boards.key(@root_board_id_key)

        json_input = { extracted_obz_data: extracted_obz_data, current_user_id: current_user&.id, group_name: file_name, root_board_id: @root_board_id }
        ImportFromObfJob.perform_async(json_input.to_json)
        render json: { status: "ok", message: "Importing OBZ file #{file_name} - Root board ID: #{@root_board_id}" }
        # render json: { created_boards: created_boards }
      else
        render json: { error: "Unsupported file format" }, status: :unprocessable_entity
      end
    elsif params[:data].present?
      boardData = params[:data].to_unsafe_h
      params[:board_group_id] = params[:board_group_id].to_i
      board_group = BoardGroup.find_by(id: params[:board_group_id]) if params[:board_group_id].present?
      if board_group
        boardData = board_group.merge({ board_group: board_group })
      end

      @board, _dynamic_data = Board.from_obf(boardData, current_user, boardData["name"], boardData["root_board_id"])
      render json: { id: @board.id }
    else
      render json: { error: "No file or data provided" }, status: :unprocessable_entity
    end
  end

  def create_additional_images
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    name_to_send = params[:name] || @board.name
    result = @board.get_words(name_to_send, num_of_words, @board.words, current_user.admin?)
    additional_words = result
    @board.find_or_create_images_from_word_list(additional_words)
    render json: @board.api_view_with_images(current_user)
  end

  def additional_words
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    board_words = @board.board_images.map(&:label).uniq
    name_to_send = params[:name] || @board.name
    additional_words = @board.get_words(name_to_send, num_of_words, board_words, current_user.admin?)
    render json: additional_words
  end

  def get_description
    set_board
    description = @board.get_description
    render json: { description: description }
  end

  def words
    additional_words = Board.new.get_word_suggestions(params[:name], params[:num_of_words], params[:words_to_exclude])

    render json: additional_words
  end

  def format_with_ai
    set_board
    screen_size = params[:screen_size] || "lg"
    FormatBoardWithAiJob.perform_async(@board.id, screen_size, true)
    @board.update(status: "formatting")
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
      new_board_image = @board.board_images.new(image_id: image.id, position: @board.board_images_count)
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
    if @board.board_type == "predictive"
      BoardImage.where(predictive_board_id: @board.id).all.each do |board_image|
        board_image.update(predictive_board_id: nil)
      end
    end
    @board.destroy!

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
    # new_name = @board.name
    @new_board = @board.clone_with_images(current_user.id, new_name)
    render json: @new_board.api_view_with_images(current_user)
  end

  def create_from_template
    obf_data = params[:data]
    user_id = current_user.id
    json_data = JSON.parse(obf_data)
    @board = Board.create_from_obf(json_data, user_id)
    render json: @board.api_view_with_images(current_user)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    @board = Board.with_artifacts.find(params[:id])
  end

  def check_board_view_edit_permissions
    set_board
    unless @board.user == current_user || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
  end

  def check_board_create_permissions
    unless current_user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    unless current_user.admin? || current_user.boards.count < current_user.board_limit
      render json: { error: "Maximum number of boards reached. Please upgrade to add more." }, status: :unprocessable_entity
      return
    end
  end

  def boards_for_user
    Board.for_user(current_user)
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
                                  :favorite,
                                  :published,
                                  :number_of_columns,
                                  :preset_display_image,
                                  :voice,
                                  :language,
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
                                  :display_image_url, :category, :word_list, :image_ids_to_remove, :board_type, settings: {})
  end

  def attach_image_to_board(image_data, file_extension)
    throw "No image data provided" unless image_data
    preset_display_img = @board.preset_display_image.attach(io: image_data, filename: "preset_display_image.#{file_extension}", content_type: image_data.content_type)
    @board.save!

    preset_display_image_url = @board.display_preset_image_url
    @board.update_preset_display_image_url(preset_display_image_url)
  end

  def save_layout!
    layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash

    # Sort layout by y and x coordinates
    sorted_layout = layout.sort_by { |item| [item["y"].to_i, item["x"].to_i] }

    board_image_ids = []
    sorted_layout.each_with_index do |item, i|
      board_image_id = item["i"].to_i
      board_image = @board.board_images.find_by(id: board_image_id)
      if board_image
        board_image.update!(position: i)
      else
        Rails.logger.error "Board image not found for ID: #{board_image_id}"
      end
    end

    # Save screen size settings
    screen_size = params[:screen_size] || "lg"
    if params[:small_screen_columns].present? || params[:medium_screen_columns].present? || params[:large_screen_columns].present?
      @board.small_screen_columns = params[:small_screen_columns].to_i if params[:small_screen_columns].present?
      @board.medium_screen_columns = params[:medium_screen_columns].to_i if params[:medium_screen_columns].present?
      @board.large_screen_columns = params[:large_screen_columns].to_i if params[:large_screen_columns].present?
    end

    # Save margin settings
    margin_x = params[:xMargin].to_i
    margin_y = params[:yMargin].to_i
    if margin_x.present? && margin_y.present?
      @board.margin_settings[screen_size] = { x: margin_x, y: margin_y }
    end

    # Save additional settings
    @board.settings[screen_size] = params[:settings] if params[:settings].present?
    @board.save!

    # Update the grid layout
    begin
      @board.update_grid_layout(sorted_layout, screen_size)
    rescue => e
      Rails.logger.error "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
    end
    @board.reload
  end
end
