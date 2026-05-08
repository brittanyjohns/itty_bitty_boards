class API::Internal::BoardsController < API::Internal::ApplicationController
  def create
    @board = Board.new(board_params)
    @board.user = current_user

    initial_board_type = params[:board_type] || board_params[:board_type]
    settings = board_params[:settings].presence || params[:settings] || {}
    settings["board_type"] = initial_board_type
    @board.board_type = initial_board_type || "static"
    @board.assign_parent

    creation_type = params[:board_creation_type].presence || "default"
    # Public boards#create overwrites board_type with creation_type after
    # assign_parent (which would otherwise force "static" for User-owned boards).
    @board.board_type = creation_type

    @board.predefined = false
    @board.small_screen_columns  = board_params["small_screen_columns"].to_i
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i
    @board.large_screen_columns  = board_params["large_screen_columns"].to_i

    voice = VoiceService.normalize_voice(board_params["voice"] || params[:voice] || params[:voice_label])
    @board.voice = voice
    @board.language = board_params["language"] if board_params["language"].present?
    @board.tags = board_params["tags"] if board_params["tags"].present?
    @board.settings = settings

    @board.slug = @board.generate_unique_slug(board_params[:slug])

    if @board.save
      enqueue_generation_job!(creation_type)
      render json: @board, status: :created
    else
      render json: { errors: @board.errors }, status: :unprocessable_entity
    end
  end

  def export_pdf
    @board = Board.find(params[:id])

    qr_requested  = ActiveModel::Type::Boolean.new.cast(params[:qr_code])
    qr_target_url = qr_requested ? params[:qr_target_url].presence : nil

    render_data = Boards::RenderAssetData.new(
      board: @board,
      screen_size: params[:screen_size] || "lg",
      hide_colors: params[:hide_colors] == "1",
      hide_header: params[:hide_header] == "1",
      routes: Rails.application.routes.url_helpers,
      include_qr: qr_requested,
      qr_target_url: qr_target_url || :default,
    ).call

    render_data.each { |k, v| instance_variable_set("@#{k}", v) }

    html = render_to_string(
      template: "api/boards/print",
      layout: "pdf",
      formats: [:html],
    )

    grover_options = {
      format: "Letter",
      landscape: @landscape,
      viewport: { width: @landscape ? 792 : 612, height: @landscape ? 612 : 792 },
      full_page: false,
      prefer_css_page_size: true,
      print_background: true,
    }

    file_data = Grover.new(html, **grover_options).to_pdf

    response.headers["Cache-Control"] = "no-store"
    send_data file_data,
      filename: "#{@board.slug}-board.pdf",
      type: "application/pdf",
      disposition: "attachment"
  end

  def update
    @board = Board.find(params[:id])
    @board.assign_attributes(board_params.except(:settings, :voice))
    @board.voice = VoiceService.normalize_voice(board_params[:voice]) if board_params[:voice].present?

    if board_params[:settings].present? || params[:settings].present?
      incoming_settings = board_params[:settings].presence || params[:settings] || {}
      @board.settings = @board.settings.merge(incoming_settings)
    end

    @board.parent_type = "User"
    @board.parent_id   = @board.user_id || User::DEFAULT_ADMIN_ID

    if board_params[:slug].present? && board_params[:slug] != @board.slug
      @board.slug = @board.generate_unique_slug(board_params[:slug])
    end

    if @board.save
      apply_layout_if_present!
      render json: @board.api_view_with_images(current_user)
    else
      render json: { errors: @board.errors }, status: :unprocessable_entity
    end
  end

  private

  def enqueue_generation_job!(creation_type)
    word_count = (params[:wordCount].presence || params[:word_count].presence || 12).to_i

    case creation_type
    when "default"
      word_list = sanitized_word_list
      return if word_list.blank?
      GenerateBoardJob.perform_async(@board.id, creation_type, { "word_list" => word_list })
    when "scenario"
      topic = params[:topic] || params[:prompt] || @board.name
      age_range = params[:ageRange].presence || params[:age_range].presence
      GenerateBoardJob.perform_async(@board.id, creation_type, { "topic" => topic, "age_range" => age_range, "word_count" => word_count })
    when "predictive"
      starting = params[:starting_phrase_or_word].presence || params[:startingPhraseOrWord].presence
      GenerateBoardJob.perform_async(
        @board.id,
        creation_type,
        {
          "word_list" => sanitized_word_list,
          "starting_phrase_or_word" => starting,
          "word_count" => word_count,
        },
      )
    else
      GenerateBoardJob.perform_async(@board.id, creation_type, { "word_count" => word_count })
    end
  end

  def sanitized_word_list
    Array(params[:word_list]).compact.select { |w| w.is_a?(String) && w.present? }
  end

  def apply_layout_if_present!
    return if params[:layout].blank?

    if params[:layout].is_a?(Array)
      layout      = params[:layout].map(&:to_unsafe_h)
      screen_size = params[:screen_size] || "lg"
    else
      layout_param = params[:layout]
      screen_size  = layout_param[:screen_size] || layout_param["screen_size"] || "lg"
      layout       = (layout_param[:layout] || layout_param["layout"] || []).map(&:to_unsafe_h)
    end

    return if @board.layout[screen_size] == layout

    @board.apply_layout!(
      layout: layout,
      screen_size: screen_size,
      columns: {
        small_screen_columns:  params[:small_screen_columns],
        medium_screen_columns: params[:medium_screen_columns],
        large_screen_columns:  params[:large_screen_columns],
      },
      margins: { x: params[:xMargin], y: params[:yMargin] },
      settings: params[:settings],
    )
  end

  def board_params
    params.require(:board).permit(
      :name,
      :slug,
      :description,
      :board_type,
      :voice,
      :language,
      :small_screen_columns,
      :medium_screen_columns,
      :large_screen_columns,
      :number_of_columns,
      :predefined,
      :published,
      :favorite,
      :category,
      :display_image_url,
      :bg_color,
      settings: {},
      tags: [],
    )
  end
end
