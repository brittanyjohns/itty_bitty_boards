class API::Internal::BoardsController < API::Internal::ApplicationController
  # Tag that marks a board as an internal marketing artifact (set by the
  # printables marketing-kit script). Only boards carrying it are eligible
  # for replace-by-slug below.
  MARKETING_TAG = "marketing".freeze

  def create
    # Opt-in stable-slug semantics for marketing artifacts: free up the exact
    # requested slug by destroying the previous kit board that held it, so the
    # printed QR target (/pb/<slug>) survives kit regenerations and scratch
    # boards don't accumulate.
    claim_marketing_slug!(board_params[:slug]) if replace_existing_slug?

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
    # Only assign columns when the param is actually present. Blind .to_i
    # turns a missing param into 0, which suppresses Board#set_screen_sizes
    # defaults (which only fill in nil) and breaks downstream callers like
    # GenerateBoardJob's `large_screen_columns || 6` (0 is truthy in Ruby).
    @board.small_screen_columns  = board_params["small_screen_columns"].to_i  if board_params["small_screen_columns"].present?
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i if board_params["medium_screen_columns"].present?
    @board.large_screen_columns  = board_params["large_screen_columns"].to_i  if board_params["large_screen_columns"].present?
    Rails.logger.info "Normalized voice for board creation: #{board_params["voice"]}, #{params[:voice]}, #{params[:voice_label]} -> #{VoiceService.normalize_voice(board_params["voice"] || params[:voice] || params[:voice_label])}"

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
      render json: { errors: @board.errors }, status: :unprocessable_content
    end
  end

  # POST /api/internal/boards/from_vocab_set
  #
  # Clone the ROOT board of a curated Board Builder vocab set (core-60 /
  # core-84) into a fresh admin-owned board the caller can immediately export
  # to PDF. v1 clones only the root grid (the poster surface), not the linked
  # fringe tree. 404s (not 500s) when the requested set isn't seeded here.
  def from_vocab_set
    root = Boards::RobustSets.find_root(params[:slug])

    if root.nil?
      render json: { error: "vocab_set_not_seeded", slug: params[:slug] }, status: :not_found
      return
    end

    board = root.clone_with_images(current_user.id, params[:name].presence || root.name)

    unless board&.persisted?
      render json: { error: "clone_failed", slug: params[:slug] }, status: :unprocessable_content
      return
    end

    # `params[:slug]` is the VOCAB SET slug; the new board's slug rides
    # `params[:board_slug]`. Claim it only after the clone persisted, so a
    # failed clone never destroys the live QR target.
    claim_marketing_slug!(params[:board_slug]) if replace_existing_slug? && params[:board_slug].present?

    finalize_cloned_vocab_board!(board)

    render json: board.api_view_with_images(current_user), status: :created
  end

  def show
    @board = Board.find(params[:id])
    render json: @board.api_view_with_images(current_user)
  end

  def export_pdf
    @board = Board.find(params[:id])

    qr_requested = ActiveModel::Type::Boolean.new.cast(params[:qr_code])
    qr_target_url = qr_requested ? params[:qr_target_url].presence : nil
    Rails.logger.info "Parameters for PDF export: #{params.to_unsafe_h.except(:board_id, :controller, :action).inspect}, QR requested: #{qr_requested}, QR target URL: #{qr_target_url}"

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

    # Opt-in marketing skin for the AAC Classroom Kit. The default template +
    # layout are shared with real users' board exports and must stay
    # byte-identical when the param is absent — the marketing variant is a
    # separate template/layout pair, never a conditional inside the shared one.
    marketing_style = params[:style] == "marketing"

    html = render_to_string(
      template: marketing_style ? "api/boards/print_marketing" : "api/boards/print",
      layout: marketing_style ? "pdf_marketing" : "pdf",
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
    @board.parent_id = @board.user_id || User::DEFAULT_ADMIN_ID

    if board_params[:slug].present? && board_params[:slug] != @board.slug
      @board.slug = @board.generate_unique_slug(board_params[:slug])
    end

    if @board.save
      apply_layout_if_present!
      render json: @board.api_view_with_images(current_user)
    else
      render json: { errors: @board.errors }, status: :unprocessable_content
    end
  end

  private

  # The clone inherits the seed root's settings via `dup`, which would carry
  # the robust-set markers and make it look like a *second* seeded root for the
  # slug (polluting Boards::RobustSets.find_root / the wizard catalog). Strip
  # them, then apply any caller-supplied tags/settings. Always saves — removing
  # the markers is itself a change.
  def finalize_cloned_vocab_board!(board)
    settings = board.settings || {}
    settings.delete(Boards::RobustSets::ROOT_MARKER)
    settings.delete(Boards::RobustSets::SLUG_MARKER)
    settings = settings.merge(params[:settings].to_unsafe_h) if params[:settings].present?
    board.settings = settings

    if params[:tags].present?
      board.tags = Array(params[:tags]).select { |t| t.is_a?(String) && t.present? }
    end

    if params[:board_slug].present?
      board.slug = board.generate_unique_slug(params[:board_slug])
    end

    board.save
  end

  def replace_existing_slug?
    ActiveModel::Type::Boolean.new.cast(params[:replace_existing_slug])
  end

  # Destroy the previous board occupying `slug` so the fresh build can take the
  # exact same one. Tightly scoped: only a board owned by the internal-API
  # admin AND tagged "marketing" is eligible. Anything else stays untouched —
  # generate_unique_slug then suffixes the new board's slug instead of
  # clobbering, and we log so the kit script's slug mismatch is explainable.
  def claim_marketing_slug!(requested_slug)
    slug = Board.create_slug(requested_slug.to_s)
    return if slug.blank?

    existing = Board.where(user_id: current_user.id, slug: slug).with_all_tags([MARKETING_TAG]).first
    if existing
      Rails.logger.info "[internal boards] replace_existing_slug: destroying marketing board #{existing.id} (#{existing.slug})"
      existing.destroy
    elsif Board.exists?(slug: slug)
      Rails.logger.warn "[internal boards] replace_existing_slug: slug #{slug.inspect} is held by a non-marketing board — leaving it; the new board will get a suffixed slug"
    end
  end

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
      layout = params[:layout].map(&:to_unsafe_h)
      screen_size = params[:screen_size] || "lg"
    else
      layout_param = params[:layout]
      screen_size = layout_param[:screen_size] || layout_param["screen_size"] || "lg"
      layout = (layout_param[:layout] || layout_param["layout"] || []).map(&:to_unsafe_h)
    end

    return if @board.layout[screen_size] == layout

    @board.apply_layout!(
      layout: layout,
      screen_size: screen_size,
      columns: {
        small_screen_columns: params[:small_screen_columns],
        medium_screen_columns: params[:medium_screen_columns],
        large_screen_columns: params[:large_screen_columns],
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
