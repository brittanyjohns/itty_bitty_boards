class API::Internal::BoardsController < API::Internal::ApplicationController
  def create
    @board = Board.new(board_params)
    @board.user = current_user
    @board.predefined = false
    @board.board_type = params[:board_type] || board_params[:board_type] || "static"
    @board.voice = VoiceService.normalize_voice(board_params[:voice]) if board_params[:voice].present?
    @board.assign_parent

    settings = board_params[:settings].presence || params[:settings] || {}
    settings["board_type"] = @board.board_type
    @board.settings = settings

    @board.slug = @board.generate_unique_slug(board_params[:slug])

    if @board.save
      render json: @board, status: :created
    else
      render json: { errors: @board.errors }, status: :unprocessable_entity
    end
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
