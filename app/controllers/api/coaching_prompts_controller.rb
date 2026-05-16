class API::CoachingPromptsController < API::ApplicationController
  before_action :set_set, only: %i[show update destroy]

  # GET /api/coaching_prompts/audio?text=...&voice=...&language=...
  # Returns the cached audio URL for a coaching phrase + voice tuple.
  # First request for a tuple synthesizes (Polly/OpenAI), uploads to S3, and
  # persists the row; subsequent requests return the same URL immediately.
  def audio
    text = params[:text].to_s.strip
    voice = params[:voice].presence || "polly:kevin"
    language = params[:language].presence || "en"

    if text.blank?
      render json: { error: "text is required" }, status: :bad_request
      return
    end

    if text.length > 500
      render json: { error: "text too long" }, status: :unprocessable_entity
      return
    end

    record = CoachingPhraseAudio.find_or_generate!(
      text: text,
      voice: voice,
      language: language,
    )

    if record.nil? || !record.audio.attached?
      render json: { error: "audio_unavailable" }, status: :service_unavailable
      return
    end

    render json: record.api_view
  end

  # GET /api/coaching_prompts
  # GET /api/coaching_prompts?board_id=:id
  def index
    if params[:board_id].present?
      board = Board.find_by(id: params[:board_id])
      unless board
        render json: { error: "Board not found" }, status: :not_found
        return
      end

      set = CoachingPromptGenerator.for(board)
      render json: set.api_view_for(current_user)
      return
    end

    sets = visible_sets_scope
    render json: sets.map { |s| s.api_view_for(current_user) }
  end

  # GET /api/coaching_prompts/:id
  def show
    render json: @set.api_view_for(current_user)
  end

  # POST /api/coaching_prompts
  def create
    set = CoachingPromptSet.new(create_params.merge(
      user_id: current_user.id,
      source: "curated",
      slug: unique_user_slug(create_params[:slug].presence || create_params[:name]),
    ))
    if set.save
      render json: set.api_view_for(current_user), status: :created
    else
      render json: { errors: set.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/coaching_prompts/:id
  def update
    unless @set.editable_by?(current_user)
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    if @set.update(update_params)
      render json: @set.api_view_for(current_user)
    else
      render json: { errors: @set.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/coaching_prompts/:id
  def destroy
    unless @set.editable_by?(current_user)
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    @set.destroy
    head :no_content
  end

  private

  def set_set
    @set = CoachingPromptSet.find_by(id: params[:id])
    render json: { error: "Not found" }, status: :not_found unless @set
  end

  # Curated published SpeakAnyWay sets + the current user's own sets.
  def visible_sets_scope
    user_id = current_user.id
    CoachingPromptSet.where(
      "(source = 'curated' AND published = TRUE AND user_id IS NULL) OR user_id = ?",
      user_id,
    ).order(:name)
  end

  def create_params
    params.require(:coaching_prompt_set).permit(
      :name,
      :slug,
      :description,
      :language,
      match_tags: [],
      strategies: [:label, :hint, { example_phrases: [] }],
    )
  end

  def update_params
    params.require(:coaching_prompt_set).permit(
      :name,
      :description,
      :language,
      :published,
      match_tags: [],
      strategies: [:label, :hint, { example_phrases: [] }],
    )
  end

  def unique_user_slug(seed)
    base = seed.to_s.parameterize.presence || "set"
    base = "user_#{current_user.id}_#{base}"
    slug = base
    i = 1
    while CoachingPromptSet.exists?(slug: slug)
      slug = "#{base}-#{i}"
      i += 1
    end
    slug
  end
end
