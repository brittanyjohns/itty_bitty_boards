class API::BoardsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[ index predictive_image_board show public_boards public_menu_boards common_boards pdf ]

  before_action :set_board, only: %i[ associate_image remove_image destroy associate_images print pdf assign_accounts show ]
  before_action :check_board_view_edit_permissions, only: %i[update destroy]
  before_action :check_board_create_permissions, only: %i[ create clone ]

  def index
    limit_param = params[:limit].presence&.to_i
    page_param = params[:page].presence || 1
    page = page_param.to_i <= 0 ? 1 : page_param.to_i
    per_page = (limit_param || 30).clamp(1, 200)

    sort_field_param = params[:sort_field].presence || "created_at"
    sort_order_param = params[:sort_order].presence || "desc"

    allowed_sort_fields = %w[name created_at updated_at]
    allowed_sort_orders = %w[asc desc]

    sort_field = allowed_sort_fields.include?(sort_field_param) ? sort_field_param : "created_at"
    sort_order = allowed_sort_orders.include?(sort_order_param) ? sort_order_param : "desc"

    order_clause = { sort_field => sort_order.to_sym }

    query = params[:query].to_s.strip.presence
    filter_param = params[:filter].to_s.strip.presence

    raw_tags = params[:tags]
    selected_tags = Array(raw_tags)
      .flat_map { |tag| tag.to_s.split(",") }
      .map { |tag| Board.normalize_tag_value(tag) }
      .reject(&:blank?)
      .uniq

    if filter_param.present? && !Board::SAFE_FILTERS.include?(filter_param)
      render json: { error: "Invalid filter" }, status: :unprocessable_entity
      return
    end
    filter = filter_param

    public_tags = Board.public_boards_tags
    # ---------------------------
    # 1. GUEST (no current_user)
    # ---------------------------
    unless current_user
      static_scope = Board.public_boards
      static_scope = static_scope.with_all_tags(selected_tags) if selected_tags.present?

      last_modified = static_scope.maximum(:updated_at) || Time.zone.at(0)
      etag = guest_boards_index_etag(last_modified, limit_param, tags: selected_tags)

      return unless stale?(etag: etag, last_modified: last_modified)

      static_scope = static_scope.order(order_clause)
      static_scope = static_scope.page(page).per(per_page)

      static_boards = static_scope.to_a
      payload = static_boards.map(&:api_view)

      render json: {
               boards: payload,
               public_tags: public_tags,
               pagination: {
                 page: static_scope.current_page,
                 per_page: static_scope.limit_value,
                 total_pages: static_scope.total_pages,
                 total_count: static_scope.total_count,
               },
             }
      return
    end

    # ---------------------------
    # 2. SEARCH MODE
    # ---------------------------
    if query.present?
      search_scope = Board.for_user(current_user).searchable
      search_scope = apply_filter(search_scope, filter)
      search_scope = search_scope.with_any_tags(selected_tags) if selected_tags.present?
      search_scope = search_scope.search_by_name(query)
      search_scope = search_scope.order(order_clause)
      search_scope = search_scope.page(page).per(per_page)

      last_updated_at = search_scope.maximum(:updated_at)&.to_i

      cache_key = [
        "boards-search-v3",
        current_user.id,
        query,
        filter || "no-filter",
        selected_tags.sort.join("|").presence || "no-tags",
        page,
        per_page,
        sort_field,
        sort_order,
        last_updated_at,
      ]

      result = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        boards_array = search_scope.to_a.map { |board| board.api_view(current_user) }

        {
          boards: boards_array,
          page: search_scope.current_page,
          per_page: search_scope.limit_value,
          total_pages: search_scope.total_pages,
          total_count: search_scope.total_count,
        }
      end

      render json: {
               boards: result[:boards],
               public_tags: public_tags,
               pagination: {
                 page: result[:page],
                 per_page: result[:per_page],
                 total_pages: result[:total_pages],
                 total_count: result[:total_count],
               },
             }
      return
    end

    # ---------------------------
    # 3. NORMAL MODE (no search)
    # ---------------------------
    base_scope = current_user.boards
    filtered_scope = apply_filter(base_scope, filter)
    filtered_scope = filtered_scope.with_any_tags(selected_tags) if selected_tags.present?

    last_modified = boards_index_last_modified(current_user, filtered_scope)
    etag = boards_index_etag(
      current_user,
      per_page,
      filtered_scope,
      last_modified,
      filter: filter,
      sort_field: sort_field,
      sort_order: sort_order,
      page: page,
      tags: selected_tags,
    )

    return unless stale?(etag: etag, last_modified: last_modified)

    user_boards_scope = filtered_scope
      .reorder(order_clause)
      .page(page)
      .per(per_page)

    @user_boards = user_boards_scope.to_a

    @newly_created_boards = filtered_scope
      .where("created_at >= ?", 1.week.ago)
      .reorder(created_at: :desc)
      .limit(7)
      .to_a

    render json: {
             newly_created_boards: @newly_created_boards.map { |board| board.api_view(current_user) },
             boards: @user_boards.map { |board| board.api_view(current_user) },
             public_tags: public_tags,
             pagination: {
               page: user_boards_scope.current_page,
               per_page: user_boards_scope.limit_value,
               total_pages: user_boards_scope.total_pages,
               total_count: user_boards_scope.total_count,
             },
           }
  end

  def public_boards
    scope = Board.public_boards

    last_modified = scope.maximum(:updated_at) || Time.zone.at(0)
    etag = public_boards_etag(scope, last_modified)

    return unless stale?(etag: etag, last_modified: last_modified)

    @public_boards = scope.to_a

    render json: { public_boards: @public_boards.map { |board| board.api_view(current_user) } }
  end

  def list
    scope = current_user.boards.alphabetical

    last_modified = boards_list_last_modified(current_user, scope)
    etag = boards_list_etag(current_user, scope, last_modified)

    return unless stale?(etag: etag, last_modified: last_modified)

    @boards = scope.to_a

    render json: { boards: @boards.map { |board| board.list_api_view(current_user) } }
  end

  def common_boards
    @common_boards = Board.common_boards
    render json: { common_boards: @common_boards.map { |board| board.api_view(current_user) } }
  end

  def public_menu_boards
    @public_menu_boards = Board.public_menu_boards.alphabetical.all
    render json: { public_menu_boards: @public_menu_boards.map(&:api_view), public_tags: Board.public_boards_tags }
  end

  def categories
    @categories = Board.board_categories
    render json: @categories
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.alphabetical
    @boards = current_user.boards.user_made_with_scenarios.alphabetical

    render json: { boards: @boards, dynamic_boards: current_user.boards.dynamic.alphabetical, public_tags: Board.public_boards_tags }
  end

  def predictive_image_board
    board = find_board_for_predictive_page

    voice = params[:voice].presence
    voice = "openai:alloy" if voice == "alloy"
    effective_voice = voice || board.voice

    last_modified = board_predictive_last_modified(board)

    etag = [
      board_predictive_etag(board, current_user),
      effective_voice,
    ]

    return unless stale?(etag: etag, last_modified: last_modified, template: false)

    payload = RailsPerformance.measure("Predictive Image Board") do
      board.api_view_for_native_grid(current_user, false, effective_voice)
    end

    render json: payload
  end

  def show
    # if stale?(etag: @board, last_modified: @board.updated_at)
    #   RailsPerformance.measure("Show Board") do
    # @loaded_board = Board.with_artifacts.find(@board.id)
    unless @board
      render json: { error: "Board not found" }, status: :not_found
      Rails.logger.error "SHOW - Board not found for ID: #{params[:id]}"
      return
    end

    @board_with_images = @board.api_view_with_predictive_images(current_user, true)
    # end
    render json: @board_with_images
    # end
  end

  def initial_predictive_board
    @board = Board.predictive_default
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

  def rearrange_images
    set_board
    @board.reset_layouts
    @board.save!
    broadcast_board_update!
    render json: @board.api_view_with_images(current_user)
  end

  def create
    @board = Board.new(board_params)
    @board.user = current_user
    board_type = params[:board_type] || board_params[:board_type]
    settings = !board_params[:settings].blank? ? board_params[:settings] : params[:settings] || {}
    settings["board_type"] = board_type
    @board.board_type = board_type || "static"
    @board.assign_parent

    creation_type = params[:board_creation_type] || "default"
    @board.board_type = creation_type

    @board.predefined = false
    @board.small_screen_columns = board_params["small_screen_columns"].to_i
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @board.large_screen_columns = board_params["large_screen_columns"].to_i
    voice = VoiceService.normalize_voice(board_params["voice"] || params[:voice] || params[:voice_label])
    @board.voice = voice
    @board.language = board_params["language"] if board_params["language"].present?
    @board.tags = board_params["tags"] if board_params["tags"].present?
    @board.settings = settings

    new_slug = @board.generate_unique_slug(board_params["slug"])
    @board.slug = new_slug

    respond_to do |format|
      if @board.save
        word_count = params[:wordCount].presence || params[:word_count].presence.to_i || 12
        case creation_type
        when "default"
          word_list = params[:word_list]&.compact
          if word_list.present?
            GenerateBoardJob.perform_async(@board.id, creation_type, { "word_list" => word_list })
          end
        when "scenario"
          topic = params[:topic] || params[:prompt] || @board.name
          age_range = params[:ageRange].presence || params[:age_range].presence
          GenerateBoardJob.perform_async(@board.id, creation_type, { "topic" => topic, "age_range" => age_range, "word_count" => word_count })
        else
          GenerateBoardJob.perform_async(@board.id, creation_type, { "word_count" => word_count })
        end
        format.json { render json: @board, status: :created }
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    @board = Board.find(params[:id])
    @board_user = @board.user
    unless current_user.can_edit?(@board)
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
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
      voice = VoiceService.normalize_voice(board_params["voice"] || params[:voice] || params[:voice_label])
      @board.voice = voice
      @board.name = board_params["name"] unless board_params["name"].blank?
      @board.description = board_params["description"]
      @board.display_image_url = board_params["display_image_url"]
      @board.bg_color = board_params["bg_color"] if board_params["bg_color"].present?
      # @board.update_preset_display_image_url(board_params["display_image_url"]) if board_params["display_image_url"].present?
      @board.predefined = board_params["predefined"]
      @board.category = board_params["category"]
      @board.tags = board_params["tags"] if board_params["tags"].present?
      @board.language = board_params["language"] if board_params["language"].present?
      @board.favorite = board_params["favorite"] if board_params["favorite"].present?
      @board.published = board_params["published"] if board_params["published"].present?
      if board_params["slug"].present? && board_params["slug"] != @board.slug
        new_slug = @board.generate_unique_slug(board_params["slug"])
        @board.slug = new_slug
      end

      @board.vendor_id = current_user.vendor_id if current_user.vendor_id.present?

      board_type = params[:board_type] || board_params[:board_type]
      settings = !board_params[:settings].blank? ? board_params[:settings] : params[:settings] || {}
      settings["board_type"] = board_type

      @board.parent_type = "User"
      @board.parent_id = @board_user&.id || User::DEFAULT_ADMIN_ID
      new_board_settings = @board.settings.merge(settings)
      @board.settings = new_board_settings
      @board.set_text_color(board_params["text_color"]) if board_params["text_color"].present?

      word_list = params["word_list"] || []
      duplicate_words = params[:duplicate_words] || false
      words_to_create = []
      current_word_list = @board.current_word_list
      word_list.each do |word|
        if word.is_a?(String) && word.present?
          if current_word_list.include?(word) && !duplicate_words
            next
          end
          words_to_create << word
        end
      end

      if !words_to_create.blank?
        @board.find_or_create_images_from_word_list(words_to_create)
      end

      respond_to do |format|
        if @board.save
          if params[:layout].present?
            # only save if changes are present
            layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash
            if @board.layout != layout
              save_layout!
            end
          end
          broadcast_board_update!
          format.json { render json: @board.api_view_with_images(current_user), status: :ok }
        else
          format.json { render json: @board.errors, status: :unprocessable_entity }
        end
      end
    end
  end

  def regenerate_images
    set_board
    return unless check_monthly_limit("ai_action")
    board_image_ids = params[:board_image_ids]
    if board_image_ids.blank? || !board_image_ids.is_a?(Array)
      render json: { error: "board_image_ids parameter is required and must be an array" }, status: :unprocessable_entity
      return
    end
    board_images = @board.board_images.where(id: board_image_ids)
    if board_images.empty?
      render json: { error: "No valid board images found for the provided IDs" }, status: :unprocessable_entity
      return
    end
    image_ids = board_images.pluck(:image_id)
    image_ids.each_slice(3) do |batch|
      GenerateImagesJob.perform_async(batch, @board.id)
    end
    render json: { status: "ok", message: "Image regeneration job started" }
  end

  def recategorize_images
    set_board
    return unless check_monthly_limit("ai_action")
    board_image_ids = @board.board_images.pluck(:id)
    board_image_ids.each_slice(20) do |batch|
      RecategorizeImagesJob.perform_async("BoardImage", batch)
    end
    render json: { status: "ok", message: "Recategorization job started for board images" }
  end

  def set_colors
    set_board
    results = []
    @board.board_images.each do |board_image|
      results << board_image.set_colors!
    end
    if results.all? { |res| res == true }
      render json: @board.api_view_with_images(current_user)
    else
      Rails.logger.error "Setting colors failed for some images: #{results.inspect}"
      render json: { error: "Setting colors failed for some images" }, status: :unprocessable_entity
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

  def analyze_obz
    uploaded_file = params[:file]
    report = ObzAnalyzer.analyze(uploaded_file.read)
    render json: report
  end

  def import_obf
    if params[:file].present?
      uploaded_file = params[:file]
      file_name = uploaded_file.original_filename
      group_name = params[:group_name] || "Imported #{file_name || Time.now.to_i}"
      file_extension = File.extname(file_name).downcase

      if file_extension == ".obz"
        begin
          file_bytes = uploaded_file.read
          @board_group = BoardGroup.create!(name: group_name, user_id: current_user.id)
          importer = ObzImporter.new(file_bytes, current_user, board_group: @board_group, import_all: true)
          result = importer.import!
          root_board = result[:root_board]
        rescue => e
          Rails.logger.error "OBZ import failed: #{e.message}"
          render json: { error: "OBZ import failed: #{e.message}" }, status: :unprocessable_entity
          return
        end

        if result
          render json: { status: "ok", message: "Importing OBZ file #{file_name} - Root board ID: #{@root_board_id}" }
        else
          render json: { error: "OBZ import failed" }, status: :unprocessable_entity
        end
        # ImportFromObzJob.perform_async(json_data, current_user&.id)
        # render json: { status: "ok", message: "Importing OBZ file #{file_name} - Root board ID: #{@root_board_id}" }
        # render json: { created_boards: created_boards }
        # render json: { error: "OBZ import temporarily disabled" }, status: :unprocessable_entity
      else
        render json: { error: "Unsupported file format" }, status: :unprocessable_entity
      end
    elsif params[:data].present?
      boardData = params[:data]&.to_json
      params[:board_group_id] = params[:board_group_id].to_i
      board_group = BoardGroup.find_by(id: params[:board_group_id]) if params[:board_group_id].present?
      if board_group
        boardData = board_group.merge({ board_group: board_group })
      end

      json_data = JSON.parse(boardData) rescue nil
      unless json_data
        render json: { error: "Invalid JSON data" }, status: :unprocessable_entity
        return
      end
      board_name = json_data["name"] || "Imported Board"

      # Board.from_obf(boardData, current_user, board_group, @board.id)
      ImportFromObfJob.perform_async(json_data, current_user.id, board_group&.id)
      render json: { status: "ok", message: "Importing OBF data for board #{board_name}" }
    else
      render json: { error: "No file or data provided" }, status: :unprocessable_entity
    end
  end

  def additional_words
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    board_words = @board.board_images.map(&:label).uniq
    name_to_send = params[:prompt] || params[:name] || @board.name
    additional_words = @board.get_words(name_to_send, num_of_words, board_words, current_user.admin?)
    render json: additional_words
  end

  def get_description
    set_board
    description = @board.get_description
    render json: { description: description }
  end

  def words
    if params[:name].blank?
      render json: { error: "Name parameter is required" }, status: :unprocessable_entity
      return
    end
    if params[:num_of_words].blank? || params[:num_of_words].to_i <= 0
      render json: { error: "num_of_words parameter must be a positive integer" }, status: :unprocessable_entity
      return
    end
    if params[:num_of_words].to_i > 50
      render json: { error: "num_of_words parameter cannot exceed 50" }, status: :unprocessable_entity
    end
    if params[:board_id].present?
      @board = Board.find_by(id: params[:board_id])
    end
    return unless check_monthly_limit("ai_action")
    creation_type = params[:board_creation_type] || "default"
    additional_words = []
    prompt = params[:prompt].presence || params[:name]
    num_of_words = params[:num_of_words].to_i || 24
    words_to_exclude = params[:words_to_exclude].is_a?(Array) ? params[:words_to_exclude] : @board&.current_word_list || []

    if creation_type == "social_story"
      number_of_steps = params[:number_of_steps].to_i
      additional_words = Board.new.get_social_story_word_suggestions(prompt, number_of_steps, num_of_words, words_to_exclude)
    elsif creation_type == "predictive"
      additional_words = Board.new.get_words_for_predictive(prompt, num_of_words)
    else
      board_name = @board&.name || prompt
      if prompt == board_name
        additional_words = Board.new.get_word_suggestions(prompt, num_of_words, words_to_exclude)
      else
        additional_words = Board.new.get_word_suggestions_from_default_prompt(prompt, num_of_words)
      end
    end
    if additional_words.blank?
      Rails.logger.error "No additional words found for prompt: #{prompt} - creation_type: #{creation_type}"
      render json: { error: "No additional words found" }, status: :unprocessable_entity
      return
    end
    unless additional_words.is_a?(Array)
      Rails.logger.error "Invalid response from word suggestion service: #{additional_words.inspect}"
      render json: { error: "Invalid response from word suggestion service" }, status: :unprocessable_entity
      return
    end
    normalize_words = additional_words.map do |word|
      next unless word.is_a?(String)
      word.gsub("_", " ").strip
    end
    render json: normalize_words
  end

  def format_with_ai
    return unless check_monthly_limit("ai_action")
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
      broadcast_board_update!

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
      broadcast_board_update!
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

    broadcast_board_update!
    render json: { board: @board, new_board_images: new_board_images }
  end

  def add_to_groups
    @board = Board.find(params[:id])

    if params[:board_group_ids].blank?
      render json: { error: "No board group IDs provided" }, status: :unprocessable_entity
      return
    elsif params[:board_group_ids].is_a?(String)
      board_group_ids = params[:board_group_ids].split(",").map(&:strip).map(&:to_i)
    elsif params[:board_group_ids].is_a?(Array)
      board_group_ids = params[:board_group_ids].map(&:to_i)
    else
      render json: { error: "Invalid board group IDs format" }, status: :unprocessable_entity
      return
    end
    board_group_ids.each do |board_group_id|
      board_group = BoardGroup.find_by(id: board_group_id)
      Rails.logger.debug "Processing board group #{board_group.id} for board #{@board.id}"
      if board_group.nil?
        Rails.logger.error "Board group with ID #{board_group_id} not found"
        next
      end
      if board_group.boards.include?(@board)
        Rails.logger.debug "Board #{@board.id} already exists in group #{board_group.id}"
      else
        Rails.logger.debug "Adding board #{@board.id} to group #{board_group.id}"
        board_group.add_board(@board)
        board_group.save
      end
    end
    @board.reload
    # render json: { message: "Board added to groups successfully" }
    @board_with_images = @board.api_view_with_predictive_images(current_user, true)
    # end
    render json: @board_with_images
  end

  def assign_accounts
    communicator_account_ids = params[:communicator_account_ids] || []
    if communicator_account_ids
      record_errors = []
      if communicator_account_ids.is_a?(String) || communicator_account_ids.is_a?(Integer)
        communicator_account_ids = [communicator_account_ids.to_i]
      end
      communicator_account_ids.each do |communicator_account_id|
        communicator_account = ChildAccount.find(communicator_account_id)
        if communicator_account.is_demo?
          board_count = communicator_account.child_boards.all.count
          demo_limit = (communicator_account.settings["demo_board_limit"] || ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT).to_i
          if board_count >= demo_limit
            record_errors << "Board limit reached for demo account #{communicator_account.name} - limit: #{demo_limit}"
            next
          end
        end
        voice = communicator_account.voice
        communicator_board_copy = @board.clone_with_images(current_user&.id, @board.name, voice, communicator_account)
      end
      if record_errors.empty?
        @board.in_use = true
        @board.save!
        @board.reload
        render json: @board.api_view_with_predictive_images(current_user, true), status: :ok
      else
        render json: { error: { message: record_errors } }, status: :unprocessable_entity
      end
    else
      render json: { error: { message: "No board_ids provided" } }, status: :unprocessable_entity
    end
  end

  def remove_image
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_entity
      return
    end
    @board_image = BoardImage.find_by(id: params[:board_image_id])
    @board.remove_board_image(@board_image&.id) if @board && @board_image
    @board.reload
    render json: @board.api_view_with_predictive_images(current_user)
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
    # new_name = "Copy of " + @board.name
    new_name = @board.name
    @new_board = @board.clone_with_images(current_user.id, new_name)
    @new_board.vendor_id = current_user.vendor_id if current_user.vendor_id.present?
    @new_board.save!
    render json: @new_board.api_view_with_images(current_user)
  end

  def create_from_template
    obf_data = params[:data]
    user_id = current_user.id
    json_data = JSON.parse(obf_data)
    @board = Board.create_from_obf(json_data, user_id)
    render json: @board.api_view_with_images(current_user)
  end

  def generate_preview_image
    set_board
    @board.run_generate_preview_job
    render json: { status: "ok", message: "Preview image generation job started" }
  end

  def pdf
    render_data = Boards::RenderAssetData.new(
      board: @board,
      screen_size: params[:screen_size] || "lg",
      hide_colors: params[:hide_colors] == "1",
      hide_header: params[:hide_header] == "1",
      routes: Rails.application.routes.url_helpers,
    ).call

    render_data.each do |key, value|
      instance_variable_set("@#{key}", value)
    end

    html = render_to_string(
      template: "api/boards/print",
      layout: "pdf",
      formats: [:html],
    )

    disp = params[:preview].present? ? "inline" : "attachment"
    response.headers["Cache-Control"] = "no-store"

    grover_options = {
      format: "Letter",
      landscape: @landscape,
      viewport: {
        width: @landscape ? 792 : 612,
        height: @landscape ? 612 : 792,
      },
      full_page: false,
      prefer_css_page_size: true,
      print_background: true,
    }

    file_data = Grover.new(html, **grover_options).to_pdf

    unless @board.pdf_file.attached?
      @board.pdf_file.attach(
        io: StringIO.new(file_data),
        filename: "#{@board.slug}-board.pdf",
        content_type: "application/pdf",
      )
    end

    send_data file_data,
      filename: "#{@board.slug}-board.pdf",
      type: "application/pdf",
      disposition: disp
  end

  private

  def check_board_create_permissions
    return if current_user.admin?
    unless current_user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    refreshed_user = User.find(current_user.id)
    refreshed_user.boards.reload
    user_board_count = refreshed_user.boards.where(predefined: false).count
    if user_board_count >= refreshed_user.board_limit
      render json: { error: "Maximum number of boards reached (#{user_board_count}/#{refreshed_user.board_limit}). Please upgrade to add more." }, status: :unprocessable_entity
      return
    end
  end

  def apply_filter(scope, filter)
    return scope unless filter.present?
    if filter == "public_boards"
      return Board.public_boards # <-- remove .alphabetical
    end
    scope.public_send(filter)
  end

  def public_boards_etag(scope, last_modified)
    [
      "public-boards-v2",
      last_modified.to_i,
      scope.maximum(:id),
      scope.count,
    ]
  end

  def boards_list_last_modified(user, scope)
    scope.maximum(:updated_at) || user.updated_at || Time.zone.at(0)
  end

  def boards_list_etag(user, scope, last_modified)
    [
      "boards-list-v1",
      user.id,
      last_modified.to_i,
      scope.maximum(:id),
      scope.count,
    ]
  end

  def guest_boards_index_etag(last_modified, limit_param, tags: [])
    [
      "guest-boards-index-v2",
      last_modified&.to_i,
      limit_param,
      Array(tags).sort.join("|"),
    ]
  end

  def boards_index_last_modified(user, base_scope)
    # If you want to be extra strict, you could also consider BoardImage etc here.
    base_scope.maximum(:updated_at) || user.updated_at || Time.zone.at(0)
  end

  def boards_index_etag(user, per_page, base_scope, last_modified, filter:, sort_field:, sort_order:, page:, tags: [])
    [
      "user-boards-index-v2",
      user.id,
      filter || "no-filter",
      sort_field,
      sort_order,
      page,
      per_page,
      Array(tags).sort.join("|"),
      last_modified.to_i,
      base_scope.maximum(:id),
      base_scope.count,
    ]
  end

  def find_board_for_predictive_page
    key = params[:slug].presence || params[:id].presence

    Board.find_by(id: key) ||
      Board.find_by(slug: key) ||
      Board.predictive_default(current_user)
  end

  def board_predictive_last_modified(board)
    # uses MAX(updated_at) across the stuff that affects this JSON
    BoardImage
      .where(board_id: board.id)
      .joins(:image)
      .left_joins(image: :docs)
      .maximum("GREATEST(board_images.updated_at, images.updated_at, COALESCE(docs.updated_at, '1970-01-01'))") ||
      board.updated_at
  end

  def board_predictive_etag(board, user)
    # include user role/settings if that changes output
    [
      "predictive-board",
      board.id,
      board.updated_at.to_i,
      user&.id,
      Digest::MD5.hexdigest((user&.settings || {}).to_json),
    ]
  end

  def broadcast_board_update!
    @board.reload
    @board.broadcast_board_update!
  end

  def qr_data_url_for(url, size: 512, border_modules: 1)
    qr = RQRCode::QRCode.new(url)
    png = qr.as_png(size: size, border_modules: border_modules)
    "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    key = params[:slug].presence || params[:id].presence

    @board = Board.find_by(id: key) ||
             Board.find_by(slug: key)
    unless @board
      render json: { error: "Board not found" }, status: :not_found
      return
    end
  end

  def check_board_view_edit_permissions
    set_board
    unless @board.user == current_user || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
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
                                  :slug,
                                  :text_color,
                                  :bg_color,
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
                                  :display_image_url, :category, :image_ids_to_remove, :board_type, settings: {}, margin_settings: {}, tags: [])
  end

  def attach_image_to_board(image_data, file_extension)
    throw "No image data provided" unless image_data
    preset_display_img = @board.preset_display_image.attach(io: image_data, filename: "preset_display_image.#{file_extension}", content_type: image_data.content_type)
    @board.save!

    preset_display_image_url = @board.display_preset_image_url
    @board.update_preset_display_image_url(preset_display_image_url)
    @board.display_image_url = preset_display_image_url
    @board.save!
  end

  def save_layout!
    if !@board || params[:layout].blank?
      Rails.logger.error "Cannot save layout: Board not found or layout parameter is blank"
      return
    end
    layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash
    sorted_layout = layout.sort_by { |item| [item["y"].to_i, item["x"].to_i] }

    board_image_ids = []
    sorted_layout.each_with_index do |item, i|
      board_image_id = item["i"].to_i
      board_image = @board&.board_images.find_by(id: board_image_id)
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
      @board.run_generate_preview_job
    rescue => e
      Rails.logger.error "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
    end
    @board.reload
  end
end
