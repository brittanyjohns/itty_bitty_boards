class API::DocsController < API::ApplicationController
  before_action :authenticate_token!

  before_action :set_doc, only: %i[ show edit update destroy ]

  # GET /docs or /docs.json
  def index
    set_scoped_docs
    # @docs = Doc.image_docs.order(created_at: :desc).page params[:page]
    search_param = params[:query]&.strip
    puts "search_param: #{search_param}"
    if params[:query].present?
      @docs = @docs.where("processed ILIKE ?", "%#{search_param}%").order(processed: :asc).page params[:page]
    else
      @docs = @docs.order(processed: :asc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "docs", locals: { docs: @docs }
    else
      render :index
    end
  end

  def find_or_create_image
    @doc = Doc.unscoped.find(params[:id])
    @label = params[:label]
    puts "Processing #{@label} for doc id #{@doc.id}"

    @image = Image.searchable_images_for(current_user).find_or_create_by(label: @label)
    @doc.update!(documentable_id: @image.id, documentable_type: "Image", deleted_at: nil)
    redirect_back_or_to @image
  end

  def deleted
    @docs = Doc.hidden.order(created_at: :desc).page params[:page]
    search_param = params[:query]&.strip
    if params[:query].present?
      @docs = @docs.where("processed ILIKE ?", "%#{search_param}%").order(processed: :asc).page params[:page]
    else
      @docs = @docs.order(processed: :asc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "docs", locals: { docs: @docs }
    else
      render :deleted
    end
  end

  # GET /docs/1 or /docs/1.json
  def show
  end

  # GET /docs/new
  def new
    @doc = Doc.new
  end

  # GET /docs/1/edit
  def edit
  end

  # POST /docs or /docs.json
  def create
    @doc = Doc.new(doc_params)
    @doc.user = current_user
    # This endpoint is reached by a person uploading their own file, so record
    # that provenance. Only filled when blank: doc_params permits :source_type,
    # and an explicit value (e.g. an admin recording a symbol source) is a
    # deliberate claim we shouldn't silently overwrite.
    @doc.source_type = Doc::SOURCE_TYPE_USER if @doc.source_type.blank?
    @documentable = @doc.documentable if @doc.documentable

    respond_to do |format|
      if @doc.save
        if @documentable.is_a?(Menu)
          @documentable.enhance_image_description
        else
          @image = @documentable
          UserDoc.create(user_id: current_user.id, doc_id: @doc.id, image_id: @image.id)
        end
        format.html { redirect_to @doc.documentable, notice: "Doc was successfully created." }
        # `location: @doc` would resolve to `doc_url`, but the route lives under
        # `namespace :api`, so the helper is `api_doc_url`. There is also no
        # app/views/api/docs/show template — `render :show` raises. Both faults
        # fired only after the Doc was saved, so the record was created and the
        # client still got a 500. Render the same api_view #update does.
        format.json do
          render json: @doc.api_view(current_user),
                 status: :created,
                 location: api_doc_url(@doc)
        end
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @doc.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /docs/1 or /docs/1.json
  def update
    # Broken-access-control gate (#469): set_doc uses Doc.unscoped.find, so
    # without this check any authenticated user could mutate any doc's content.
    unless current_user&.can_edit?(@doc)
      respond_to do |format|
        format.html { redirect_back_or_to root_url, notice: "You do not have permission to edit this doc." }
        format.json { render json: { error: "Unauthorized" }, status: :forbidden }
      end
      return
    end

    respond_to do |format|
      if @doc.update(doc_params)
        format.html { redirect_to api_doc_url(@doc), notice: "Doc was successfully updated." }
        format.json { render json: @doc.api_view(current_user), status: :ok }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @doc.errors, status: :unprocessable_content }
      end
    end
  end

  def move
    @doc = Doc.find(params[:id])
    unless current_user&.can_edit?(@doc)
      redirect_back_or_to root_url, notice: "You do not have permission to edit this doc."
    end
    if params[:documentable_type] == "Image"
      @image = Image.find(params[:documentable_id])
      @doc.update(documentable_id: @image.id, documentable_type: "Image")
      redirect_to @image
    else
      puts "**** ERROR ****"
    end
  end

  # Point an Image at a different picture.
  #
  # Three separate things can happen here and they have three different scopes:
  #
  #   * the caller's OWN preference   -> a UserDoc row. Always written.
  #   * the LIBRARY default           -> docs.current + images.src_url. Only an
  #     actor who may edit the Image (its owner, or an admin for the shared
  #     library) may move it, because Images are shared across every account.
  #   * existing TILES                -> Images::TileArtFanout, which reaches
  #     the actor's and admin's boards only. Once a board exists, its tile art
  #     belongs to that board's owner; a library change must not repaint it.
  def mark_as_current
    @doc = Doc.find(params[:id])
    @image = @doc.documentable
    unless @image.is_a?(Image)
      render json: { error: "Doc is not attached to an image." }, status: :unprocessable_content
      return
    end

    # The board whose tile we're being asked to pin. Must be one the caller may
    # edit: this was unscoped, so any authenticated user could repaint a tile
    # on ANY board by passing its id (#469-class IDOR). Mirrors the guard in
    # Api::ImagesController#check_update_board_image.
    @board = Board.find_by(id: params[:board_id])
    @board = nil unless @board && current_user.can_edit?(@board)

    ActiveRecord::Base.transaction do
      current_user.user_docs.where(image_id: @image.id).destroy_all
      UserDoc.create!(user_id: current_user.id, doc_id: @doc.id, image_id: @image.id)
    end

    # src_url is the URL a newly created tile snapshots (BoardImage#set_defaults),
    # so moving it is how a library change reaches FUTURE boards. The cascade it
    # fires is scoped by fanout_actor_id.
    if @image.set_library_default_doc!(@doc, actor: current_user)
      @image.fanout_actor_id = current_user.id
      @image.update(src_url: @doc.tile_url)
    end

    if @board
      @board_image = @board.board_images.find_by(image_id: @image.id)
      @board_image&.update(display_image_url: @doc.tile_url)
      @board.broadcast_board_update!
    end

    # "Apply to all my boards" — the actor's and admin's boards, never a
    # stranger's, and never a tile whose picture was deliberately switched off.
    if params[:update_all]
      Images::TileArtFanout.call(@image, url: @doc.tile_url, actor: current_user, force: true)
    end

    render json: {
      image: nil,
      board: @board&.api_view(current_user),
      board_image: @board_image&.api_view(current_user),
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Not found." }, status: :not_found
  rescue => e
    # Never leak internals in API errors — generic message only.
    Rails.logger.error "mark_as_current failed for doc #{params[:id]}: #{e.class}: #{e.message}"
    render json: { error: "Unable to update this picture." }, status: :unprocessable_content
  end

  # DELETE /docs/1 or /docs/1.json
  def destroy
    # Broken-access-control gate, the same one #update carries (#469): set_doc
    # uses Doc.unscoped.find, so without this any authenticated user could
    # delete any doc — including the shared library art every board falls back
    # to. #update was fixed and destroy was missed.
    unless current_user&.can_edit?(@doc)
      respond_to do |format|
        format.html { redirect_back_or_to root_url, notice: "You do not have permission to delete this doc." }
        format.json { render json: { error: "Unauthorized" }, status: :forbidden }
      end
      return
    end

    documentable = @doc.documentable
    if params[:hard_delete]
      @doc.destroy
    else
      # `hide!`, not `hide` — the model defines only the bang form, so this
      # raised NoMethodError and the soft-delete path never worked at all.
      @doc.hide!
    end

    respond_to do |format|
      format.html { redirect_back_or_to documentable, notice: "Doc was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private

  def set_scoped_docs
    case params[:scope]
    when "symbols"
      @docs = Doc.symbols.order(created_at: :desc).page params[:page]
    when "ai_generated"
      @docs = Doc.ai_generated.order(created_at: :desc).page params[:page]
    else
      @docs = Doc.all.order(created_at: :desc).page params[:page]
    end
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_doc
    @doc = Doc.unscoped.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def doc_params
    # :user_id is intentionally NOT permitted — the owner is assigned server-side
    # (@doc.user = current_user in #create), so a client can't set or reassign
    # ownership via create/update mass-assignment (#27).
    permitted = params.require(:doc).permit(:documentable_id, :documentable_type, :image, :raw, :current, :board_id, :source_type)
    # `current` is the LIBRARY DEFAULT on a shared row, admin-only — same
    # treatment board_params gives :slug / :predefined. A user's own pick is a
    # UserDoc, which already outranks `current` in Image#display_doc.
    permitted.delete(:current) unless current_user&.admin?
    permitted
  end
end
